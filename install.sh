#!/usr/bin/env bash
# =============================================================================
# install.sh — H&M Fashion Clone on AWS EKS — Full Bootstrap Script
# Region: ap-south-1 (Mumbai)  |  Cluster: three-tier-cluster
# =============================================================================
set -euo pipefail

# ── Logging ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/install.log"
> "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m';  YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m';   RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }
phase()   { echo -e "\n${MAGENTA}${BOLD}▶▶▶ $* ──────────────────────────────────────────${RESET}\n"; }

# ── Flag parsing ───────────────────────────────────────────────────────────────
SKIP_TERRAFORM=false
SKIP_JENKINS=false
SKIP_MONITORING=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --skip-terraform)  SKIP_TERRAFORM=true  ;;
    --skip-jenkins)    SKIP_JENKINS=true    ;;
    --skip-monitoring) SKIP_MONITORING=true ;;
    --dry-run)         DRY_RUN=true         ;;
    --help)
      echo "Usage: $0 [--skip-terraform] [--skip-jenkins] [--skip-monitoring] [--dry-run]"
      exit 0
      ;;
  esac
done

# ── Config ─────────────────────────────────────────────────────────────────────
AWS_REGION="ap-south-1"
CLUSTER_NAME="three-tier-cluster"
K8S_NAMESPACE="hm-shop"
ARGOCD_NAMESPACE="argocd"
MONITORING_NAMESPACE="monitoring"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
K8S_DIR="${SCRIPT_DIR}/k8s_manifests"
ARGOCD_DIR="${SCRIPT_DIR}/argocd"
MONITORING_DIR="${SCRIPT_DIR}/monitoring"
SSH_KEY_PATH="${SSH_KEY_PATH:-${SCRIPT_DIR}/hm-eks-key.pem}"
START_TIME=$(date +%s)

# ── Banner ─────────────────────────────────────────────────────────────────────
print_banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  cat << 'BANNER'
  ██╗  ██╗ ██╗ ███╗   ███╗    ███████╗██╗  ██╗███████╗
  ██║  ██║ ██║ ████╗ ████║    ██╔════╝██║ ██╔╝██╔════╝
  ███████║ ██║ ██╔████╔██║    █████╗  █████╔╝ ███████╗
  ██╔══██║ ██║ ██║╚██╔╝██║    ██╔══╝  ██╔═██╗ ╚════██║
  ██║  ██║ ██║ ██║ ╚═╝ ██║    ███████╗██║  ██╗███████║
  ╚═╝  ╚═╝ ╚═╝ ╚═╝     ╚═╝    ╚══════╝╚═╝  ╚═╝╚══════╝
       AWS EKS DevSecOps — Three-Tier Fashion Clone
BANNER
  echo -e "${RESET}"
  echo -e "  ${BOLD}Region:${RESET}  ${AWS_REGION} (Mumbai)"
  echo -e "  ${BOLD}Cluster:${RESET} ${CLUSTER_NAME}"
  echo -e "  ${BOLD}Log:${RESET}     ${LOG_FILE}"
  echo -e "\n  ${YELLOW}${BOLD}⚠  Cost Warning: ~\$11.52/day in ap-south-1. Run ./uninstall.sh when done.${RESET}\n"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "  ${MAGENTA}${BOLD}[ DRY RUN MODE — no real resources will be created ]${RESET}\n"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Preflight Checks
# ─────────────────────────────────────────────────────────────────────────────
phase_preflight() {
  phase "PHASE 1 — Preflight Checks"

  local required_tools=(aws terraform kubectl helm curl jq git docker ssh scp)
  local missing=()

  for tool in "${required_tools[@]}"; do
    if command -v "${tool}" &>/dev/null; then
      success "${tool} found: $(${tool} --version 2>&1 | head -1)"
    else
      warn "${tool} not found"
      missing+=("${tool}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing tools: ${missing[*]}. Install with: sudo apt install ${missing[*]}"
  fi

  info "Verifying AWS credentials..."
  local identity
  identity=$(aws sts get-caller-identity --output json) || error "AWS credentials not configured. Run: aws configure"
  AWS_ACCOUNT_ID=$(echo "${identity}" | jq -r '.Account')
  AWS_CALLER_ARN=$(echo "${identity}" | jq -r '.Arn')
  success "AWS Account: ${AWS_ACCOUNT_ID}"
  success "Caller ARN:  ${AWS_CALLER_ARN}"
  export AWS_ACCOUNT_ID

  if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    warn "SSH key not found at ${SSH_KEY_PATH}"
    read -rp "Continue without SSH key? Jenkins setup will be skipped [y/N]: " cont
    [[ "${cont,,}" == "y" ]] || error "Aborted. Create key with: aws ec2 create-key-pair --key-name hm-eks-key --region ${AWS_REGION} --query KeyMaterial --output text > hm-eks-key.pem && chmod 400 hm-eks-key.pem"
    SKIP_JENKINS=true
  fi

  local remote
  remote=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ -n "${remote}" ]]; then
    GITHUB_USER=$(echo "${remote}" | sed -E 's|.*github.com[:/]([^/]+)/.*|\1|')
    GITHUB_REPO=$(echo "${remote}" | sed -E 's|.*/||; s|\.git$||')
    success "GitHub: ${GITHUB_USER}/${GITHUB_REPO}"
  else
    warn "No git remote configured. GitOps push will be skipped."
    GITHUB_USER="<YOUR_GITHUB_USERNAME>"
    GITHUB_REPO="<YOUR_REPO_NAME>"
  fi

  if [[ "${DRY_RUN}" == "false" ]]; then
    echo ""
    read -rp "All checks passed. Continue with full deployment? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted by user."; exit 0; }
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Terraform Infrastructure
# ─────────────────────────────────────────────────────────────────────────────
phase_terraform() {
  phase "PHASE 2 — Terraform Infrastructure (EKS + ECR + IAM)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Skipping Terraform apply"
    ECR_FRONTEND_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/hm-frontend"
    ECR_BACKEND_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/hm-backend"
    return
  fi

  cd "${TERRAFORM_DIR}"

  if [[ "${SKIP_TERRAFORM}" == "true" ]]; then
    info "Skipping Terraform apply (--skip-terraform). Reading existing outputs..."
    ECR_FRONTEND_URL=$(terraform output -raw ecr_frontend_url 2>/dev/null || echo "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/hm-frontend")
    ECR_BACKEND_URL=$(terraform output  -raw ecr_backend_url  2>/dev/null || echo "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/hm-backend")
    ECR_PULL_ROLE_FRONTEND=$(terraform output -raw ecr_pull_role_arn_frontend 2>/dev/null || echo "arn:aws:iam::${AWS_ACCOUNT_ID}:role/hm-shop-frontend-ecr-role")
    ECR_PULL_ROLE_BACKEND=$(terraform  output -raw ecr_pull_role_arn_backend  2>/dev/null || echo "arn:aws:iam::${AWS_ACCOUNT_ID}:role/hm-shop-backend-ecr-role")
  else
    info "Running terraform init..."
    terraform init -input=false

    info "Validating configuration..."
    terraform validate

    info "Creating execution plan..."
    terraform plan -out=tfplan -input=false

    info "Applying infrastructure (this takes 15-20 minutes)..."
    terraform apply tfplan

    ECR_FRONTEND_URL=$(terraform output -raw ecr_frontend_url)
    ECR_BACKEND_URL=$(terraform  output -raw ecr_backend_url)
    ECR_PULL_ROLE_FRONTEND=$(terraform output -raw ecr_pull_role_arn_frontend)
    ECR_PULL_ROLE_BACKEND=$(terraform  output -raw ecr_pull_role_arn_backend)
    JENKINS_IP=$(terraform output -raw jenkins_public_ip 2>/dev/null || echo "")
    success "Terraform apply complete"
    success "ECR Frontend: ${ECR_FRONTEND_URL}"
    success "ECR Backend:  ${ECR_BACKEND_URL}"
  fi

  cd "${SCRIPT_DIR}"

  info "Injecting AWS Account ID into K8s manifests..."
  find "${K8S_DIR}" -name "*.yaml" -exec sed -i "s|<YOUR_AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" {} \;
  sed -i "s|<YOUR_GITHUB_USERNAME>|${GITHUB_USER}|g"   "${ARGOCD_DIR}/application.yaml" 2>/dev/null || true
  sed -i "s|<YOUR_REPO_NAME>|${GITHUB_REPO}|g"         "${ARGOCD_DIR}/application.yaml" 2>/dev/null || true
  sed -i "s|<YOUR_AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" Jenkinsfile 2>/dev/null || true
  sed -i "s|<YOUR_GITHUB_USERNAME>|${GITHUB_USER}|g"   Jenkinsfile 2>/dev/null || true
  sed -i "s|<YOUR_REPO_NAME>|${GITHUB_REPO}|g"         Jenkinsfile 2>/dev/null || true

  info "Committing manifest updates to git..."
  git add "${K8S_DIR}/" "${ARGOCD_DIR}/" Jenkinsfile 2>/dev/null || true
  git commit -m "CI: Inject AWS Account ID ${AWS_ACCOUNT_ID} into manifests" 2>/dev/null || warn "Nothing to commit or git push failed"
  git push 2>/dev/null || warn "Git push failed — push manually if needed"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — EKS Bootstrap
# ─────────────────────────────────────────────────────────────────────────────
phase_eks_bootstrap() {
  phase "PHASE 3 — EKS Bootstrap (kubeconfig + EBS CSI + Metrics Server)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Skipping EKS bootstrap"; return
  fi

  info "Configuring kubectl..."
  aws eks update-kubeconfig \
    --region "${AWS_REGION}" \
    --name   "${CLUSTER_NAME}"

  info "Waiting for nodes to be Ready..."
  local retries=30
  local count=0
  until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    count=$((count + 1))
    if [[ ${count} -ge ${retries} ]]; then
      error "Nodes did not become Ready after $((retries * 10)) seconds"
    fi
    info "Waiting for nodes... attempt ${count}/${retries}"
    sleep 10
  done
  success "Nodes are Ready:"
  kubectl get nodes

  info "Installing AWS EBS CSI Driver addon..."
  aws eks create-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name   "aws-ebs-csi-driver" \
    --region       "${AWS_REGION}" 2>/dev/null || info "EBS CSI addon already exists"

  info "Waiting for EBS CSI addon to be ACTIVE..."
  local addon_retries=18
  local addon_count=0
  until aws eks describe-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name   "aws-ebs-csi-driver" \
    --region       "${AWS_REGION}" \
    --query "addon.status" --output text 2>/dev/null | grep -q "ACTIVE"; do
    addon_count=$((addon_count + 1))
    if [[ ${addon_count} -ge ${addon_retries} ]]; then
      warn "EBS CSI addon not ACTIVE yet — continuing (may cause PVC issues)"
      break
    fi
    info "Waiting for EBS CSI... attempt ${addon_count}/${addon_retries}"
    sleep 10
  done
  success "EBS CSI Driver is ACTIVE"
  kubectl get pods -n kube-system | grep ebs || true

  info "Installing Metrics Server (required for HPA)..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

  info "Applying StorageClass..."
  kubectl apply -f "${K8S_DIR}/storageclass.yaml"
  success "StorageClass hm-ebs-gp2 applied"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — Controllers (ALB + Cluster Autoscaler + IngressClass)
# ─────────────────────────────────────────────────────────────────────────────
phase_controllers() {
  phase "PHASE 4 — AWS Controllers (ALB Controller + Cluster Autoscaler)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Skipping controller installation"; return
  fi

  info "Adding Helm repositories..."
  helm repo add eks           https://aws.github.io/eks-charts            2>/dev/null || true
  helm repo add autoscaler    https://kubernetes.github.io/autoscaler     2>/dev/null || true
  helm repo update

  local VPC_ID
  VPC_ID=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)
  success "VPC ID: ${VPC_ID}"

  local ALB_ROLE_ARN
  ALB_ROLE_ARN=$(cd "${TERRAFORM_DIR}" && terraform output -raw alb_controller_role_arn 2>/dev/null || \
    echo "arn:aws:iam::${AWS_ACCOUNT_ID}:role/hm-shop-alb-controller-role")

  info "Installing AWS Load Balancer Controller..."
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="${CLUSTER_NAME}" \
    --set region="${AWS_REGION}" \
    --set vpcId="${VPC_ID}" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${ALB_ROLE_ARN}" \
    --wait --timeout=300s
  success "AWS Load Balancer Controller installed"
  kubectl get deployment -n kube-system aws-load-balancer-controller
  info "Waiting for ALB controller to be fully ready..."
  kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

  local CA_ROLE_ARN
  CA_ROLE_ARN=$(cd "${TERRAFORM_DIR}" && terraform output -raw cluster_autoscaler_role_arn 2>/dev/null || \
    echo "arn:aws:iam::${AWS_ACCOUNT_ID}:role/hm-shop-cluster-autoscaler-role")

  info "Installing Cluster Autoscaler..."
  helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
    --namespace kube-system \
    --set autoDiscovery.clusterName="${CLUSTER_NAME}" \
    --set awsRegion="${AWS_REGION}" \
    --set rbac.serviceAccount.create=true \
    --set rbac.serviceAccount.name=cluster-autoscaler \
    --set "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${CA_ROLE_ARN}" \
    --set extraArgs.balance-similar-node-groups=true \
    --set extraArgs.skip-nodes-with-system-pods=false \
    --wait --timeout=180s
  success "Cluster Autoscaler installed"
  kubectl get deployment -n kube-system -l "app.kubernetes.io/name=aws-cluster-autoscaler"

  info "Applying IngressClass..."
  kubectl apply -f "${K8S_DIR}/ingressclass.yaml"
  success "IngressClass 'alb' applied"
  kubectl get ingressclass
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 — Jenkins EC2 Setup
# ─────────────────────────────────────────────────────────────────────────────
phase_jenkins() {
  phase "PHASE 5 — Jenkins EC2 Setup"

  if [[ "${SKIP_JENKINS}" == "true" ]]; then
    warn "Skipping Jenkins setup (--skip-jenkins)"
    return
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Skipping Jenkins setup"; return
  fi

  # Auto-detect Jenkins EC2 IP
  local JENKINS_IP=""
  JENKINS_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=jenkins-server" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --region "${AWS_REGION}" \
    --output text 2>/dev/null || echo "")

  if [[ -z "${JENKINS_IP}" || "${JENKINS_IP}" == "None" ]]; then
    warn "Jenkins EC2 not found via tag. Enter IP manually:"
    read -rp "Jenkins EC2 Public IP: " JENKINS_IP
  fi

  success "Jenkins EC2 IP: ${JENKINS_IP}"
  info "Bootstrapping Jenkins via SSH (this takes 5-8 minutes)..."

  ssh -o StrictHostKeyChecking=no \
      -o ConnectTimeout=30 \
      -i "${SSH_KEY_PATH}" \
      "ubuntu@${JENKINS_IP}" bash << 'REMOTE_SCRIPT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== Installing Java 17 ==="
if ! command -v java &>/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y openjdk-17-jdk
fi
java -version

echo "=== Installing Jenkins ==="
if ! command -v jenkins &>/dev/null; then
  # Clean up ALL previous attempts
  sudo rm -f /usr/share/keyrings/jenkins-keyring.asc \
             /usr/share/keyrings/jenkins-keyring.gpg \
             /etc/apt/trusted.gpg.d/jenkins.asc \
             /etc/apt/trusted.gpg.d/jenkins.gpg \
             /etc/apt/sources.list.d/jenkins.list
  # Fetch key by ID directly from Ubuntu keyserver — no file/format/permission issues
  sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 7198F4B714ABFC68
  echo "deb https://pkg.jenkins.io/debian-stable binary/" \
    | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y jenkins
  sudo systemctl enable jenkins
  sudo systemctl start jenkins
fi
sudo systemctl status jenkins --no-pager

echo "=== Installing Docker ==="
if ! command -v docker &>/dev/null; then
  sudo apt-get install -y docker.io
  sudo systemctl enable docker
  sudo systemctl start docker
fi
sudo usermod -aG docker jenkins || true
sudo usermod -aG docker ubuntu  || true
sudo systemctl restart jenkins
docker --version

echo "=== Installing AWS CLI v2 ==="
if ! command -v aws &>/dev/null; then
  sudo apt-get install -y unzip
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  sudo /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
aws --version

echo "=== Installing kubectl ==="
if ! command -v kubectl &>/dev/null; then
  KUBECTL_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm kubectl
fi
kubectl version --client

echo "=== Installing SonarScanner 5.0.1.3006 ==="
if ! command -v sonar-scanner &>/dev/null; then
  SONAR_VERSION="5.0.1.3006"
  curl -fsSLO "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_VERSION}-linux.zip"
  sudo unzip -q "sonar-scanner-cli-${SONAR_VERSION}-linux.zip" -d /opt/
  sudo ln -sf "/opt/sonar-scanner-${SONAR_VERSION}-linux/bin/sonar-scanner" /usr/local/bin/sonar-scanner
  rm "sonar-scanner-cli-${SONAR_VERSION}-linux.zip"
fi
sonar-scanner --version

echo "=== Installing Trivy ==="
if ! command -v trivy &>/dev/null; then
  # Clean up ALL previous attempts
  sudo rm -f /usr/share/keyrings/trivy.asc \
             /usr/share/keyrings/trivy.gpg \
             /etc/apt/trusted.gpg.d/trivy.asc \
             /etc/apt/trusted.gpg.d/trivy.gpg \
             /etc/apt/sources.list.d/trivy.list
  curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
  echo "deb https://aquasecurity.github.io/trivy-repo/deb generic main" \
    | sudo tee /etc/apt/sources.list.d/trivy.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y trivy
fi
trivy --version

echo "=== Setting vm.max_map_count for SonarQube ==="
sudo sysctl -w vm.max_map_count=524288
grep -qxF 'vm.max_map_count=524288' /etc/sysctl.conf || echo 'vm.max_map_count=524288' | sudo tee -a /etc/sysctl.conf

echo "=== Jenkins Initial Admin Password ==="
sudo cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "(not yet generated — wait for Jenkins to start)"

echo ""
echo "=== Jenkins EC2 Bootstrap Complete ==="
REMOTE_SCRIPT

  success "Jenkins EC2 bootstrap complete!"
  JENKINS_IP_SAVED="${JENKINS_IP}"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 — ArgoCD
# ─────────────────────────────────────────────────────────────────────────────
phase_argocd() {
  phase "PHASE 6 — ArgoCD (GitOps Controller)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Skipping ArgoCD installation"; return
  fi

  info "Creating ArgoCD namespace..."
  kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  info "Removing stale ALB webhook configs to prevent TLS errors during ArgoCD install..."
  kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true
  kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook 2>/dev/null || true

  info "Installing ArgoCD..."
  # --server-side avoids 'annotation too long' error on ArgoCD CRDs
  kubectl apply --server-side -n "${ARGOCD_NAMESPACE}" \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  info "Waiting for ArgoCD server to be Available (up to 3 minutes)..."
  kubectl wait deployment/argocd-server \
    --namespace "${ARGOCD_NAMESPACE}" \
    --for=condition=Available \
    --timeout=180s

  ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NAMESPACE}" \
    get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
  success "ArgoCD initial admin password: ${ARGOCD_PASSWORD}"

  info "Deploying ArgoCD Application (hm-shop)..."
  kubectl apply -f "${ARGOCD_DIR}/application.yaml"
  success "ArgoCD Application deployed — will sync within 3 minutes"

  info "To access ArgoCD UI, run:"
  echo "  kubectl port-forward svc/argocd-server -n ${ARGOCD_NAMESPACE} 8443:443"
  echo "  Then open: https://localhost:8443 (admin / ${ARGOCD_PASSWORD})"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 — Monitoring (Prometheus + Grafana)
# ─────────────────────────────────────────────────────────────────────────────
phase_monitoring() {
  phase "PHASE 7 — Monitoring Stack (Prometheus + Grafana)"

  if [[ "${SKIP_MONITORING}" == "true" ]]; then
    warn "Skipping monitoring stack (--skip-monitoring)"
    return
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Skipping monitoring installation"; return
  fi

  info "Creating monitoring namespace..."
  kubectl create namespace "${MONITORING_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  info "Adding Helm repos for monitoring..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo add grafana              https://grafana.github.io/helm-charts              2>/dev/null || true
  helm repo update

  info "Installing Prometheus (kube-prometheus-stack)..."
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace "${MONITORING_NAMESPACE}" \
    --values "${MONITORING_DIR}/prometheus-values.yaml" \
    --timeout=300s \
    --wait

  info "Installing Grafana..."
  helm upgrade --install grafana grafana/grafana \
    --namespace "${MONITORING_NAMESPACE}" \
    --values "${MONITORING_DIR}/grafana-values.yaml" \
    --timeout=180s \
    --wait

  info "Waiting for Grafana LoadBalancer external IP..."
  local grafana_count=0
  local grafana_retries=18
  GRAFANA_URL=""
  until [[ -n "${GRAFANA_URL}" && "${GRAFANA_URL}" != "<pending>" && "${GRAFANA_URL}" != "None" ]]; do
    grafana_count=$((grafana_count + 1))
    if [[ ${grafana_count} -ge ${grafana_retries} ]]; then
      warn "Grafana LB IP not provisioned yet — check manually: kubectl get svc -n ${MONITORING_NAMESPACE} grafana"
      GRAFANA_URL="<pending>"
      break
    fi
    GRAFANA_URL=$(kubectl get svc grafana -n "${MONITORING_NAMESPACE}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    [[ -z "${GRAFANA_URL}" ]] && GRAFANA_URL=$(kubectl get svc grafana -n "${MONITORING_NAMESPACE}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    info "Waiting for Grafana LB... attempt ${grafana_count}/${grafana_retries}"
    sleep 10
  done
  success "Grafana URL: http://${GRAFANA_URL}  (admin / HMGrafana2024!)"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 8 — Jenkins Pipeline Setup
# ─────────────────────────────────────────────────────────────────────────────
phase_pipeline() {
  phase "PHASE 8 — Jenkins Pipeline Automation"

  if [[ "${SKIP_JENKINS}" == "true" ]]; then
    warn "Skipping Jenkins pipeline setup (--skip-jenkins)"
    return
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Skipping Jenkins pipeline setup"; return
  fi

  export AWS_REGION CLUSTER_NAME
  [[ -f "${SSH_KEY_PATH}" ]] && export SSH_KEY_PATH
  bash "${SCRIPTS_DIR}/setup-jenkins-pipeline.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 9 — Verify & Summary
# ─────────────────────────────────────────────────────────────────────────────
phase_verify() {
  phase "PHASE 9 — Verification & Summary"

  if [[ "${DRY_RUN}" == "true" ]]; then
    info "[DRY RUN] Skipping verification"; return
  fi

  info "Waiting for ALB ingress address (up to 5 minutes)..."
  local ing_count=0
  local ing_retries=30
  ALB_URL=""
  until [[ -n "${ALB_URL}" && "${ALB_URL}" != "<pending>" ]]; do
    ing_count=$((ing_count + 1))
    if [[ ${ing_count} -ge ${ing_retries} ]]; then
      warn "ALB not provisioned yet. Check: kubectl get ingress -n ${K8S_NAMESPACE}"
      ALB_URL="<check kubectl get ingress -n ${K8S_NAMESPACE}>"
      break
    fi
    ALB_URL=$(kubectl get ingress hm-shop-ingress -n "${K8S_NAMESPACE}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    [[ -z "${ALB_URL}" ]] && sleep 10 || break
  done

  local JENKINS_IP_DISP="${JENKINS_IP_SAVED:-<check Terraform output jenkins_public_ip>}"
  local elapsed=$(( ($(date +%s) - START_TIME) / 60 ))

  # Write stack-urls.txt
  cat > "${SCRIPT_DIR}/stack-urls.txt" << URLS_EOF
# H&M Shop — Stack URLs & Credentials
# Generated: $(date)
# Elapsed:   ${elapsed} minutes

Application URL:       http://${ALB_URL}
API Health Check:      http://${ALB_URL}/api/health
Grafana URL:           http://${GRAFANA_URL:-<check monitoring ns>}
Jenkins URL:           http://${JENKINS_IP_DISP}:8080
SonarQube URL:         http://${JENKINS_IP_DISP}:9000

Grafana credentials:   admin / HMGrafana2024!
SonarQube credentials: admin / Sonar@HMShop2024!
ArgoCD credentials:    admin / ${ARGOCD_PASSWORD:-<check argocd secret>}

AWS Account ID:        ${AWS_ACCOUNT_ID}
EKS Cluster:           ${CLUSTER_NAME}
AWS Region:            ${AWS_REGION}
URLS_EOF

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${GREEN}${BOLD}║         ✅  DEPLOYMENT COMPLETE in ${elapsed} minutes          ║${RESET}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "  ${BOLD}🌐 Application:${RESET}  http://${ALB_URL}"
  echo -e "  ${BOLD}📊 Grafana:${RESET}      http://${GRAFANA_URL:-<check monitoring ns>}  (admin/HMGrafana2024!)"
  echo -e "  ${BOLD}🔧 Jenkins:${RESET}      http://${JENKINS_IP_DISP}:8080"
  echo -e "  ${BOLD}🔍 SonarQube:${RESET}    http://${JENKINS_IP_DISP}:9000"
  echo -e "  ${BOLD}📋 All URLs:${RESET}     cat stack-urls.txt"
  echo ""
  echo -e "  ${YELLOW}${BOLD}⚠  Remember: Run ./uninstall.sh when finished to avoid charges (~\$11.52/day)${RESET}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
print_banner
phase_preflight
phase_terraform
phase_eks_bootstrap
phase_controllers
phase_jenkins
phase_argocd
phase_monitoring
phase_pipeline
phase_verify
