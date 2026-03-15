# H&M Fashion Clone — DevSecOps on AWS EKS


A production-grade, three-tier fashion e-commerce application deployed on AWS EKS with a full DevSecOps pipeline — security scanning, GitOps delivery, autoscaling, and observability


---

## Architecture Diagram

![Architecture Diagram](diagrams/Three-Tier-EKS-Terraform.png)


---

## Tech Stack

| Layer             | Technology                        | Purpose                                  |
|-------------------|-----------------------------------|------------------------------------------|
| Frontend          | React 18 + Nginx 1.25             | SPA served via Nginx reverse proxy       |
| Backend           | Node.js 18 + Express              | REST API with JWT auth                   |
| Database          | PostgreSQL 15                     | Relational store, EBS-backed PVC         |
| Storage           | AWS EBS gp2 (dynamic)             | Persistent volume for Postgres data      |
| Container Build   | Docker (multi-stage)              | Non-root images, minimal attack surface  |
| CI                | Jenkins on EC2                    | 6-stage security-hardened pipeline       |
| CD / GitOps       | ArgoCD (in-cluster)               | Polls GitHub, auto-syncs manifests       |
| IaC               | Terraform >= 1.5                  | VPC, EKS, ECR, IAM, EC2                  |
| Container Registry| AWS ECR Private                   | Private image storage with scan-on-push  |
| ECR Auth          | IRSA                              | IAM Role bound to K8s ServiceAccount     |
| Code Quality      | SonarQube LTS Community           | Static analysis + Quality Gate           |
| Dependency Scan   | Trivy                             | FS + container image vulnerability scans |
| Monitoring        | Prometheus + Grafana              | Metrics collection + dashboards          |
| Ingress           | AWS ALB Controller + IngressClass | Internet-facing ALB, path-based routing  |
| HPA               | autoscaling/v2                    | CPU + memory-based autoscaling           |
| Cluster Scaling   | Cluster Autoscaler                | Node-level scale-out                     |

---

## Prerequisites

### Local Machine Requirements

#### 1. AWS CLI v2

The AWS CLI allows you to interact with AWS services from your terminal.

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip
sudo ./aws/install
aws --version
# Expected: aws-cli/2.x.x Python/3.x.x Linux/...
```

Configure your credentials:

```bash
aws configure
# AWS Access Key ID [None]:     AKIAIOSFODNN7EXAMPLE
# AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
# Default region name [None]:   ap-south-1
# Default output format [None]: json
```

- **Verify:** `aws sts get-caller-identity` returns your Account ID and ARN.

---

#### 2. Terraform >= 1.5

Terraform provisions all AWS infrastructure declaratively.

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt-get update && sudo apt-get install terraform
terraform --version
# Expected: Terraform v1.5.x or higher
```

- **Verify:** `terraform --version` shows 1.5+.

---

#### 3. kubectl

The Kubernetes command-line tool for interacting with your EKS cluster.

```bash
KUBECTL_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
# Expected: Client Version: v1.29.x
```

- **Verify:** `kubectl version --client` shows a version number.

---

#### 4. Helm v3

Helm is the package manager for Kubernetes — used to install ALB Controller, Autoscaler, Prometheus, and Grafana.

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
# Expected: version.BuildInfo{Version:"v3.x.x", ...}
```

- **Verify:** `helm version` shows v3.x.

---

#### 5. Docker

Docker builds your frontend and backend container images.

```bash
sudo apt-get install -y docker.io
sudo systemctl enable docker && sudo systemctl start docker
sudo usermod -aG docker $USER
newgrp docker
docker --version
# Expected: Docker version 24.x.x, build ...
```

- **Verify:** `docker run hello-world` completes without permission errors.

---

#### 6. Supporting tools (jq, git, curl)

```bash
sudo apt-get install -y jq git curl
jq --version    # jq-1.6
git --version   # git version 2.x.x
curl --version  # curl 7.x.x
```

---

#### 7. EC2 Key Pair for Jenkins SSH

An SSH key pair is required to access the Jenkins EC2 for setup (Step 12c).

```bash
# Create the key pair in ap-south-1
aws ec2 create-key-pair --key-name hm-eks-key --region ap-south-1 --query KeyMaterial --output text > hm-eks-key.pem

chmod 400 hm-eks-key.pem
```

- **Verify:** `ls -la hm-eks-key.pem` shows `-r--------` permissions.

---

#### 8. GitHub Repository

Fork or clone this repository under your own GitHub account:

```bash
git clone https://github.com/Abhiram-Rakesh/Three-Tier-EKS-Terraform.git
cd Three-Tier-EKS-Terraform
```

Or if creating fresh:

```bash
git init
git remote add origin https://github.com/Abhiram-Rakesh/Three-Tier-EKS-Terraform.git
git add . && git commit -m "Initial commit"
git push -u origin main
```

---

### AWS IAM Requirements

Your IAM user/role needs the following policies attached for terraform to create the infra:

| Policy | Why It's Needed |
|--------|----------------|
| `AmazonEKSFullAccess` | Create and manage EKS clusters |
| `AmazonEC2FullAccess` | Provision EC2, VPC, subnets, security groups |
| `AmazonVPCFullAccess` | Create VPC, subnets, route tables, NAT GWs |
| `AmazonECR_FullAccess` | Create ECR repos, lifecycle policies |
| `IAMFullAccess` | Create IRSA roles, OIDC providers, policies |
| Inline ECR pull policy | Allow nodes to pull from ECR (added by irsa.tf) |

---

## Deployment — Step-by-Step

---

### Step 1 — Clone the Repository

```bash
git clone https://github.com/Abhiram-Rakesh/Three-Tier-EKS-Terraform.git
cd Three-Tier-EKS-Terraform
```

Expected output:
```
Cloning into 'Three-Tier-EKS-Terraform'...
remote: Enumerating objects: 87, done.
Receiving objects: 100% (87/87), done.
```

- **Success indicator:** `ls` shows Jenkinsfile, terraform/, k8s_manifests/, app/

---

### Step 2 — Provision Infrastructure (Terraform)

```bash
cd terraform

terraform init -input=false
terraform plan -out=tfplan -input=false
terraform apply tfplan
```

Expected output (last lines of apply):
```
Apply complete! Resources: 34 added, 0 changed, 0 destroyed.

Outputs:

cluster_endpoint           = "https://XXXXXXXXXXXXXXXX.gr7.ap-south-1.eks.amazonaws.com"
ecr_frontend_url           = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/hm-frontend"
ecr_backend_url            = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/hm-backend"
ecr_pull_role_arn_frontend = "arn:aws:iam::123456789012:role/hm-shop-frontend-ecr-role"
ecr_pull_role_arn_backend  = "arn:aws:iam::123456789012:role/hm-shop-backend-ecr-role"
alb_controller_role_arn    = "arn:aws:iam::123456789012:role/hm-shop-alb-controller-role"
jenkins_public_ip          = "13.233.x.x"
aws_account_id             = "123456789012"
```

Export outputs as shell variables:

```bash
export AWS_ACCOUNT_ID=$(terraform output -raw aws_account_id)
export ECR_FRONTEND=$(terraform output -raw ecr_frontend_url)
export ECR_BACKEND=$(terraform output -raw ecr_backend_url)
export JENKINS_IP=$(terraform output -raw jenkins_public_ip)
cd ..
```

- **Success indicator:** `aws eks list-clusters --region ap-south-1` shows `three-tier-cluster`.

---

### Step 3 — Configure kubectl

```bash
aws eks update-kubeconfig --region ap-south-1 --name three-tier-cluster

kubectl get nodes
```

Expected output:
```
NAME                                        STATUS   ROLES    AGE   VERSION
ip-10-0-10-xx.ap-south-1.compute.internal  Ready    <none>   2m    v1.29.x
ip-10-0-11-xx.ap-south-1.compute.internal  Ready    <none>   2m    v1.29.x
```

- **Success indicator:** Both nodes show `STATUS=Ready`.

---

### Step 4 — Install AWS EBS CSI Driver

**Why this is critical:** Without the EBS CSI driver, the PostgreSQL PersistentVolumeClaim will stay in `Pending` state forever. The pod will never start.

```bash
aws eks create-addon --cluster-name three-tier-cluster --addon-name aws-ebs-csi-driver --region ap-south-1

# Poll until ACTIVE
watch aws eks describe-addon --cluster-name three-tier-cluster --addon-name aws-ebs-csi-driver --region ap-south-1 --query "addon.status" --output text
```

Expected output (after 2–3 minutes):
```
ACTIVE
```

Verify the driver pods are running:

```bash
kubectl get pods -n kube-system | grep ebs
```

Expected:
```
ebs-csi-controller-xxxxxxxxx-xxxxx   6/6   Running   0   2m
ebs-csi-node-xxxxx                   3/3   Running   0   2m
ebs-csi-node-xxxxx                   3/3   Running   0   2m
```

- **Success indicator:** `ACTIVE` status and controller pod in `Running` state.

---

### Step 5 — Apply StorageClass and IngressClass

```bash
kubectl apply -f k8s_manifests/storageclass.yaml
kubectl apply -f k8s_manifests/ingressclass.yaml

kubectl get storageclass
kubectl get ingressclass
```

Expected output:
```
NAME           PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
hm-ebs-gp2    ebs.csi.aws.com         Retain          WaitForFirstConsumer   true

NAME   CONTROLLER                  PARAMETERS   AGE
alb    ingress.k8s.aws/alb         <none>        5s
```

- **Success indicator:** `hm-ebs-gp2` StorageClass and `alb` IngressClass appear.

---

### Step 6 — Install AWS Load Balancer Controller

> **Important:** Step 5 applied `k8s_manifests/ingressclass.yaml` which already created an `IngressClass "alb"` resource. Helm cannot adopt resources it did not create, so the install will fail with an ownership error unless you delete it first:
>
> ```bash
> kubectl delete ingressclass alb
> ```
>
> Helm will recreate it with the correct ownership labels during the install below.

```bash
# Get VPC ID
VPC_ID=$(aws eks describe-cluster --name three-tier-cluster --region ap-south-1 --query "cluster.resourcesVpcConfig.vpcId" --output text)

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --namespace kube-system --set clusterName=three-tier-cluster --set region=ap-south-1 --set vpcId=${VPC_ID} --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/hm-shop-alb-controller-role" --wait

kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system | grep aws-load-balancer
```

Expected:
```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   2/2     2            2           60s
```

- **Success indicator:** Deployment shows `2/2 READY`.

---

### Step 7 — Install Cluster Autoscaler

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler --namespace kube-system --set autoDiscovery.clusterName=three-tier-cluster --set awsRegion=ap-south-1 --set rbac.serviceAccount.create=true --set rbac.serviceAccount.name=cluster-autoscaler --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/hm-shop-cluster-autoscaler-role" --wait

kubectl get deployment -n kube-system cluster-autoscaler
```

- **Success indicator:** `cluster-autoscaler` deployment shows `1/1 READY`.

---

### Step 8 — Install Metrics Server (Required for HPA)

**Why:** HorizontalPodAutoscaler cannot read CPU/memory metrics without Metrics Server. HPAs will show `<unknown>` targets without it.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Wait ~60s then verify
kubectl top nodes
```

Expected output:
```
NAME                                        CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
ip-10-0-10-xx.ap-south-1.compute.internal  120m         6%     820Mi           27%
ip-10-0-11-xx.ap-south-1.compute.internal  115m         5%     790Mi           26%
```

- **Success indicator:** `kubectl top nodes` shows CPU% and MEMORY% values (not errors).

---

### Step 9 — Inject AWS Account ID into Manifests

The K8s manifests contain `<YOUR_AWS_ACCOUNT_ID>` placeholders for ECR image URLs and IRSA role ARNs. Replace them with your real account ID:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GITHUB_USER=<YOUR_USERNAME>

# Replace in all K8s manifests
find k8s_manifests/ -name "*.yaml" -exec sed -i "s|<YOUR_AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" {} \;

# Replace GitHub username in ArgoCD application
sed -i "s|<YOUR_USERNAME>|${GITHUB_USER}|g" argocd/application.yaml

# Replace in Jenkinsfile
sed -i "s|<YOUR_AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" Jenkinsfile
sed -i "s|<YOUR_USERNAME>|${GITHUB_USER}|g" Jenkinsfile

# Commit and push so ArgoCD can read the updated manifests
git add k8s_manifests/ argocd/ Jenkinsfile
git commit -m "CI: Inject AWS Account ID ${AWS_ACCOUNT_ID} into manifests"
git push origin main
```

- **Success indicator:** `grep '<YOUR_AWS_ACCOUNT_ID>' k8s_manifests/**/*.yaml` returns no output.

---

### Step 10 — Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD server to be ready
kubectl wait deployment/argocd-server --namespace argocd --for=condition=Available --timeout=180s

# Get initial admin password
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD password: ${ARGOCD_PASS}"

# Deploy the hm-shop Application
kubectl apply -f argocd/application.yaml
```

**Expose ArgoCD via a public LoadBalancer:**

By default ArgoCD's service is `ClusterIP`. Patch it to `LoadBalancer` so you can access it directly:

```bash
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# Wait for the external IP to be assigned (1-3 minutes)
kubectl get svc argocd-server -n argocd --watch
```

Once `EXTERNAL-IP` is populated:

```bash
ARGOCD_URL=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "ArgoCD URL: https://${ARGOCD_URL}"
```

Open `https://<ARGOCD_URL>` in your browser. ArgoCD redirects all HTTP traffic to HTTPS and uses a self-signed certificate — your browser will show a certificate warning. Click **Advanced → Proceed anyway** to continue.

Credentials:
- Username: `admin`
- Password: output of the `ARGOCD_PASS` command above

**What ArgoCD does automatically after this:** It polls the `k8s_manifests/` path in your GitHub repo every 3 minutes. When Jenkins pushes an updated image tag (Stage 7), ArgoCD detects the commit and applies the new manifests to the cluster — completing the GitOps loop.

- **Success indicator:** ArgoCD UI shows `hm-shop` application with status `Synced` and `Healthy`.

---

### Step 11 — Verify Application Pods

```bash
kubectl get pods -n hm-shop --watch
```

Expected output (all Running):
```
NAME                        READY   STATUS    RESTARTS   AGE
backend-xxxxxxxxx-xxxxx     1/1     Running   0          3m
backend-xxxxxxxxx-yyyyy     1/1     Running   0          3m
frontend-xxxxxxxxx-xxxxx    1/1     Running   0          3m
frontend-xxxxxxxxx-yyyyy    1/1     Running   0          3m
postgres-xxxxxxxxx-xxxxx    1/1     Running   0          5m
```

Check HPAs:

```bash
kubectl get hpa -n hm-shop
```

Expected:
```
NAME           REFERENCE             TARGETS          MINPODS   MAXPODS   REPLICAS
backend-hpa    Deployment/backend    15%/70%, 20%/80%  2         5         2
frontend-hpa   Deployment/frontend   10%/70%, 15%/80%  2         5         2
postgres-hpa   Deployment/postgres   8%/80%, 12%/85%   1         2         1
```

Check ingress (wait up to 5 minutes for ALB):

```bash
kubectl get ingress -n hm-shop
```

Expected:
```
NAME              CLASS   HOSTS   ADDRESS                                          PORTS   AGE
hm-shop-ingress   alb     *       k8s-hmshop-xxxx.ap-south-1.elb.amazonaws.com   80      5m
```

- **Success indicator:** All pods `Running`, HPAs show real percentages (not `<unknown>`), ingress `ADDRESS` field is populated.

---

### Step 12 — Set Up Jenkins EC2

#### 12a — Get Jenkins EC2 IP

```bash
JENKINS_IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=jenkins-server" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].PublicIpAddress" --region ap-south-1 --output text)
echo "Jenkins IP: ${JENKINS_IP}"
```

#### 12b — Required Security Group Ports

| Port  | Protocol | Source    | Purpose                  |
|-------|----------|-----------|--------------------------|
| 22    | TCP      | 0.0.0.0/0 | SSH access               |
| 8080  | TCP      | 0.0.0.0/0 | Jenkins web UI           |
| 9000  | TCP      | 0.0.0.0/0 | SonarQube web UI         |
| 50000 | TCP      | 0.0.0.0/0 | Jenkins agent JNLP port  |

These are created automatically by Terraform in `vpc.tf`.

#### 12c — Bootstrap the Jenkins EC2

SSH into the Jenkins EC2 and install each tool:

```bash
ssh -i hm-eks-key.pem ubuntu@${JENKINS_IP}
```

**Java 17:**
```bash
sudo apt-get update && sudo apt-get install -y openjdk-17-jdk
java -version
# openjdk version "17.0.x"
```

**Jenkins:**
```bash
# The jenkins.io-2023.key URL is outdated — Jenkins rotated their signing key.
# Fetch the actual key used to sign the repo directly from a keyserver.
gpg --keyserver keyserver.ubuntu.com --recv-keys 5E386EADB55F01504CAE8BCF7198F4B714ABFC68
gpg --export 5E386EADB55F01504CAE8BCF7198F4B714ABFC68 | sudo tee /usr/share/keyrings/jenkins-keyring.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.gpg] https://pkg.jenkins.io/debian-stable binary/" | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update && sudo apt-get install -y jenkins
sudo systemctl enable jenkins && sudo systemctl start jenkins
sudo systemctl status jenkins
# Active: active (running)
```

**Docker:**
```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker jenkins
sudo usermod -aG docker ubuntu
sudo systemctl restart jenkins
docker --version
# Docker version 24.x.x
```

> **Important:** `usermod` only takes effect in new login sessions. After running the commands above, **exit and re-SSH** into the instance before running any `docker` commands, otherwise you'll get a `permission denied` error on `/var/run/docker.sock`.
> ```bash
> exit
> ssh -i hm-eks-key.pem ubuntu@<JENKINS_IP>
> ```

**AWS CLI v2:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
sudo apt install unzip
unzip awscliv2.zip && sudo ./aws/install
aws --version
# aws-cli/2.x.x
```

**kubectl:**
```bash
KUBECTL_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

**Node.js 18:**
```bash
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version
```

**SonarScanner 5.0.1.3006:**
```bash
SONAR_VERSION="5.0.1.3006"
curl -fsSLO "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_VERSION}-linux.zip"
sudo unzip -q "sonar-scanner-cli-${SONAR_VERSION}-linux.zip" -d /opt/
sudo ln -sf "/opt/sonar-scanner-${SONAR_VERSION}-linux/bin/sonar-scanner" /usr/local/bin/sonar-scanner
sonar-scanner --version
```

**Trivy:**
```bash
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
trivy --version
```

**vm.max_map_count (required for SonarQube):**
```bash
sudo sysctl -w vm.max_map_count=524288
echo 'vm.max_map_count=524288' | sudo tee -a /etc/sysctl.conf
```

#### 12d — Get Jenkins Initial Password

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
# Output: a32-character hex string e.g. 3d4f2bf07a6c4e8...
```

#### 12e — Jenkins Browser Setup

1. Open `http://<JENKINS_IP>:8080` in your browser
2. Paste the initial admin password from 12d
3. Click **Install suggested plugins** and wait ~3 minutes
4. Create admin user: fill in username, password, full name, email
5. Click **Save and Finish** → **Start using Jenkins**

- **Success indicator:** Jenkins dashboard loads showing "Welcome to Jenkins!"

---

### Step 13 — Set Up SonarQube

**Start SonarQube on the Jenkins EC2:**

```bash
ssh -i hm-eks-key.pem ubuntu@${JENKINS_IP}

docker run -d --name sonarqube --restart unless-stopped -p 9000:9000 -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true -v sonarqube_data:/opt/sonarqube/data sonarqube:lts-community
```

Wait ~60 seconds, then open `http://<JENKINS_IP>:9000`.

**First login:**
1. Username: `admin`, Password: `admin`
2. You'll be prompted to change the password → set a strong password of your choice
3. Click **Create a local project** → Project key: `hm-fashion-clone`, Display name: `H&M Fashion Clone`
4. Click **Set up project for clean code**

**Generate a token:**
1. Click your avatar (top right) → **My Account** → **Security**
2. Under **Generate Tokens**: Name = `jenkins-token`, Type = `User Token`
3. Click **Generate** — **copy the token immediately** (shown only once)

**Install Jenkins plugins (do this before configuring SonarQube in Jenkins):**

Navigate to: **Jenkins → Manage Jenkins → Plugins → Available plugins**

Search for and install each:

- [ ] `pipeline-stage-view`
- [ ] `git`
- [ ] `github`
- [ ] `github-branch-source`
- [ ] `docker-workflow`
- [ ] `docker-plugin`
- [ ] `sonar`
- [ ] `credentials-binding`
- [ ] `pipeline-utility-steps`
- [ ] `ws-cleanup`
- [ ] `build-timeout`
- [ ] `timestamper`
- [ ] `ansicolor`
- [ ] `workflow-aggregator`

Click **Install** and wait for Jenkins to restart. The `sonar` plugin must be installed before the SonarQube server can be configured in the next step.

- **Success indicator:** Jenkins restarts and all 14 plugins show as **Installed**.

**Add token to Jenkins:**
1. Jenkins → **Manage Jenkins** → **Configure System**
2. Scroll to **SonarQube servers** section → **Add SonarQube**
3. Name: `SonarQube`, Server URL: `http://<JENKINS_IP>:9000`
4. Server authentication token → **Add** → **Jenkins** → Kind: **Secret text** → paste token
5. Click **Save**

**Create a webhook in SonarQube pointing back to Jenkins:**

This is required for the `waitForQualityGate()` step in the Jenkinsfile to work. Without it, the pipeline will hang at the quality gate stage waiting for a callback that never arrives.

1. In SonarQube, go to **Administration** → **Configuration** → **Webhooks**
2. Click **Create**
3. Fill in:
   - **Name:** `Jenkins`
   - **URL:** `http://<JENKINS_IP>:8080/sonarqube-webhook/`
   - **Secret:** leave blank (unless you've configured one in Jenkins)
4. Click **Create**

> The trailing slash in the URL (`/sonarqube-webhook/`) is required. SonarQube will POST the analysis result to this endpoint, which unblocks the Jenkins pipeline quality gate check.

- **Success indicator:** Jenkins can reach SonarQube — test via a pipeline run. The pipeline should proceed past Stage 1 without hanging.

---

### Step 14 — Configure Jenkins Credentials

Navigate to: **Jenkins → Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

| ID | Kind | Value | Security Note |
|----|------|-------|---------------|
| `aws-access-key` | Secret text | AWS Access Key ID for the IAM user | Never use personal admin keys |
| `aws-secret-key` | Secret text | AWS Secret Access Key for the IAM user | Rotate every 90 days |
| `sonar-token` | Secret text | SonarQube user token from Step 13 | Regenerate if compromised |
| `git-credentials` | Username/Password | GitHub username + PAT | PAT needs `repo` + `admin:repo_hook` scopes |

** IAM user — required policy:**

Attach a single AWS managed policy to this user — do **not** use inline policies:

| Policy Name | ARN |
|-------------|-----|
| `AmazonEC2ContainerRegistryPowerUser` | `arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser` |

This grants `ecr:GetAuthorizationToken` plus push/pull to all repos, and intentionally excludes destructive actions like deleting repos or lifecycle policies. EKS/kubectl access is handled by the Jenkins EC2 instance profile — this user is only used for ECR.

- **Success indicator:** All 4 credentials appear in the global credentials list.

---

### Step 15 — Create Jenkins Pipeline Job

1. Jenkins dashboard → **New Item**
2. Enter name: `hm-fashion-pipeline`
3. Select **Pipeline** → click **OK**
4. Under **Build Triggers**: check **GitHub hook trigger for GITScm polling**
5. Under **Pipeline**:
   - Definition: `Pipeline script from SCM`
   - SCM: `Git`
   - Repository URL: `https://github.com/<YOUR_USERNAME>/Three-Tier-EKS-Terraform.git`
   - Credentials: select `git-credentials`
   - Branch: `*/main`
   - Script Path: `Jenkinsfile`
6. Click **Save**

- **Success indicator:** Pipeline job appears in Jenkins dashboard.

---

### Step 16 — Configure GitHub Webhook

1. Go to: `https://github.com/Abhiram-Rakesh/Three-Tier-EKS-Terraform/settings/hooks/new`
2. Fill in:
   - **Payload URL:** `http://<JENKINS_IP>:8080/github-webhook/`
   - **Content type:** `application/json`
   - **Which events:** select **Just the push event**
3. Click **Add webhook**
4. GitHub will send a ping — look for a green ✓ checkmark on the webhook page

- **Success indicator:** Green checkmark on GitHub webhook page, and Jenkins shows a build was triggered.

---

### Step 17 — Trigger First Pipeline Run

```bash
git commit --allow-empty -m "CI: trigger first pipeline run"
git push origin main
```

Watch the pipeline in Jenkins at `http://<JENKINS_IP>:8080/job/hm-fashion-pipeline/`:

| Stage | What to watch for |
|-------|-------------------|
| Stage 1 (SonarQube) | Quality Gate result — must be PASSED |
| Stage 2 (Trivy FS) | Results table, pipeline continues regardless |
| Stage 3 (Build) | `Successfully built <image-id>` for both images |
| Stage 4 (ECR Push) | `The push refers to repository [...]` |
| Stage 5 (Trivy Image) | Scan results archived as artifacts |
| Stage 6 (GitOps) | `CI: Update image tags to build-1 [skip ci]` commit appears in GitHub |

After Stage 6, ArgoCD detects the new commit within 3 minutes and deploys the updated images automatically.

- **Success indicator:** All 6 stages green, ArgoCD application status shows `Synced`.

---

### Step 18 — Install Monitoring Stack

```bash
kubectl create namespace monitoring

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo update

# Install Prometheus stack
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --values monitoring/prometheus-values.yaml --wait

# Install Grafana
helm upgrade --install grafana grafana/grafana --namespace monitoring --values monitoring/grafana-values.yaml --wait
```

**Accessing Grafana:**

Grafana is configured as a `LoadBalancer` service. Wait for the NLB to be assigned (can take 2-5 minutes after the Helm install):

```bash
kubectl get svc grafana -n monitoring --watch
```

Once `EXTERNAL-IP` is populated:

```bash
GRAFANA_URL=$(kubectl get svc grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Grafana URL: http://${GRAFANA_URL}"
```

Open `http://<GRAFANA_URL>` in your browser.

Credentials:
- Username: `admin`
- Password: the value you set for `adminPassword` in `monitoring/grafana-values.yaml`

Pre-imported dashboards (under **H&M Shop** folder):
- Kubernetes Cluster (6417)
- Kubernetes Pods (6336)
- Node Exporter Full (1860)
- Nginx Ingress (9614)

**Success indicator:** Grafana loads, all 4 dashboards show live data.

---

### Step 19 — Access the Application

```bash
# Get the ALB URL
ALB_URL=$(kubectl get ingress hm-shop-ingress -n hm-shop -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test the API health endpoint
curl http://${ALB_URL}/api/health
```

Expected JSON response:
```json
{
  "status": "healthy",
  "timestamp": "2024-01-15T10:30:00.000Z",
  "service": "hm-backend",
  "database": {
    "status": "connected",
    "latency_ms": 2
  },
  "uptime_seconds": 120
}
```

Open the application in your browser:

```bash
echo "Application URL: http://${ALB_URL}"
```

**Success indicator:** Browser loads the H&M Fashion clone homepage with product listings.

---

## Day-2 Operations

### View Logs

```bash
# Backend logs (follow)
kubectl logs -f deployment/backend -n hm-shop

# Frontend logs
kubectl logs -f deployment/frontend -n hm-shop

# PostgreSQL logs
kubectl logs -f deployment/postgres -n hm-shop

# All pods in namespace
kubectl logs -f -l app=backend -n hm-shop --all-containers=true
```

### Manual Scaling + Watch HPA

```bash
# Scale backend manually
kubectl scale deployment backend --replicas=4 -n hm-shop

# Watch HPA react
kubectl get hpa -n hm-shop --watch
```

### View Security Scan Results

Trivy results are archived as Jenkins build artifacts. Access them at:
`http://<JENKINS_IP>:8080/job/hm-fashion-pipeline/<BUILD_NUMBER>/artifact/`

### Trigger Pipeline Manually

```bash
git commit --allow-empty -m "CI: manual trigger"
git push origin main
```

### ArgoCD Sync Check + Force Sync

```bash
# Check sync status
kubectl get application hm-shop -n argocd

# Force sync immediately (don't wait 3 minutes)
kubectl patch application hm-shop -n argocd --type merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{"force":true}}}}}'
```

### Rolling Restart

```bash
kubectl rollout restart deployment/frontend -n hm-shop
kubectl rollout restart deployment/backend  -n hm-shop
kubectl rollout status  deployment/backend  -n hm-shop
```

### Connect to PostgreSQL CLI

```bash
# Get the postgres pod name
POSTGRES_POD=$(kubectl get pod -n hm-shop -l app=postgres -o jsonpath='{.items[0].metadata.name}')

# Open psql
kubectl exec -it ${POSTGRES_POD} -n hm-shop -- psql -U hmuser -d hmshop

# Once inside psql:
\dt                          -- list tables
SELECT COUNT(*) FROM products;
SELECT * FROM orders LIMIT 5;
\q                           -- quit
```

---

## Teardown

### Manual Teardown (Order Matters!)

```bash
# 1. Uninstall Helm releases FIRST (triggers controller-managed LB deletion)
helm uninstall grafana              -n monitoring
helm uninstall prometheus           -n monitoring
helm uninstall cluster-autoscaler   -n kube-system
helm uninstall aws-load-balancer-controller -n kube-system

# 2. Delete namespaces (triggers ALB + EBS cleanup)
kubectl delete namespace hm-shop argocd monitoring --timeout=120s

# 3. Explicitly delete all ALBs and NLBs in the VPC via AWS CLI
# Kubernetes controllers sometimes leave LBs behind after namespace deletion.
# Terraform cannot delete the VPC while any LB ENIs still exist in subnets.
VPC_ID=$(aws ec2 describe-vpcs --region ap-south-1 --filters "Name=tag:Name,Values=hm-shop-vpc" --query "Vpcs[0].VpcId" --output text)
echo "VPC: ${VPC_ID}"

LB_ARNS=$(aws elbv2 describe-load-balancers --region ap-south-1 --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text)
if [ -n "$LB_ARNS" ]; then
  for ARN in $LB_ARNS; do
    echo "Deleting LB: $ARN"
    aws elbv2 delete-load-balancer --region ap-south-1 --load-balancer-arn $ARN
  done
  echo "Waiting 60s for LBs to finish deleting..."
  sleep 60
else
  echo "No load balancers found in VPC."
fi

# 4. Delete any leftover Target Groups (LBs must be gone first)
TG_ARNS=$(aws elbv2 describe-target-groups --region ap-south-1 --query "TargetGroups[*].TargetGroupArn" --output text)
if [ -n "$TG_ARNS" ]; then
  for TG in $TG_ARNS; do
    aws elbv2 delete-target-group --region ap-south-1 --target-group-arn $TG 2>/dev/null && echo "Deleted TG: $TG"
  done
fi

# 5. Delete any remaining ENIs in the VPC (LBs leave ENIs behind on deletion)
ENI_IDS=$(aws ec2 describe-network-interfaces --region ap-south-1 --filters "Name=vpc-id,Values=${VPC_ID}" --query "NetworkInterfaces[*].NetworkInterfaceId" --output text)
if [ -n "$ENI_IDS" ]; then
  for ENI in $ENI_IDS; do
    echo "Deleting ENI: $ENI"
    aws ec2 delete-network-interface --region ap-south-1 --network-interface-id $ENI 2>/dev/null || echo "  Skipped $ENI (still in use or already gone)"
  done
else
  echo "No leftover ENIs found."
fi

# 6. Terraform destroy
cd terraform
terraform destroy -auto-approve
```

> **Why order matters:** Terraform cannot delete the VPC while any ENIs remain in its subnets. ALBs (hm-shop ingress) and NLBs (ArgoCD, Grafana) all create ENIs. Steps 3–5 force-delete every LB, target group, and ENI before Terraform runs, so `terraform destroy` completes cleanly in one shot.

---

## Environment Variables Reference

| Variable | Where Set | Value | Notes |
|----------|-----------|-------|-------|
| `AWS_REGION` | Shell / Jenkinsfile | `ap-south-1` | All resources in Mumbai |
| `CLUSTER_NAME` | Jenkinsfile env | `three-tier-cluster` | EKS cluster name |
| `AWS_ACCOUNT_ID` | Shell (Step 9) | Your 12-digit ID | Used for ECR URL construction |
| `REGISTRY` | Jenkinsfile env | `<YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com` | Set after Step 9 substitution |
| `GIT_REPO` | Jenkinsfile env | Your GitHub repo URL | Update before first run |
| `DB_PASSWORD` | K8s Secret `backend-secret` | Set in `k8s_manifests/database/secret.yaml` | Rotate for real deployments |
| `JWT_SECRET` | K8s Secret `backend-secret` | Set in `k8s_manifests/database/secret.yaml` | Change before production use |

---

## Troubleshooting

### 1. PostgreSQL pod stuck in `Pending`

**Symptom:**
```
NAME                  READY   STATUS    RESTARTS
postgres-xxx-xxx      0/1     Pending   0
```

**Diagnosis:**
```bash
kubectl describe pod -n hm-shop -l app=postgres | grep -A 5 Events
# Look for: "no volume plugin matched" or "waiting for first consumer"
```

**Fix:**
```bash
# Verify EBS CSI Driver is ACTIVE
aws eks describe-addon --cluster-name three-tier-cluster --addon-name aws-ebs-csi-driver --region ap-south-1 --query "addon.status" --output text

# If not ACTIVE, check node role has AmazonEBSCSIDriverPolicy attached
aws iam list-attached-role-policies --role-name three-tier-cluster-node-role --query "AttachedPolicies[].PolicyName"
```

---

### 2. ALB not provisioning (Ingress ADDRESS stays empty)

**Symptom:** `kubectl get ingress -n hm-shop` shows no ADDRESS after 5+ minutes.

**Diagnosis:**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

**Fix:**
```bash
# Check VPC subnets have correct tags
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<VPC_ID>" --query "Subnets[*].{ID:SubnetId,Tags:Tags}"
# Public subnets need: kubernetes.io/role/elb = 1
# Private subnets need: kubernetes.io/role/internal-elb = 1

# Verify ALB Controller IRSA role
kubectl get sa -n kube-system aws-load-balancer-controller -o yaml | grep role-arn
```

---

### 3. ArgoCD out of sync

**Symptom:** ArgoCD UI shows `OutOfSync` or `Unknown` health.

**Diagnosis:**
```bash
kubectl describe application hm-shop -n argocd | grep -A 10 "Conditions"
```

**Fix:**
```bash
# Check repoURL in application.yaml matches your GitHub repo exactly
cat argocd/application.yaml | grep repoURL

# Check ArgoCD can reach GitHub
kubectl exec -it deployment/argocd-server -n argocd -- argocd-util repo ls

# Force a sync
kubectl patch application hm-shop -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

---

### 4. Jenkins Stage 5 fails (ECR auth error)

**Symptom:** `no basic auth credentials` or `denied: Your authorization token has expired`

**Diagnosis:**
```bash
# Check Jenkins aws-access-key credential is set
# Jenkins → Manage Jenkins → Credentials → look for aws-access-key
```

**Fix:**
```bash
# Verify the IAM user has ECR permissions
aws iam list-attached-user-policies --user-name <IAM-USER-NAME>
# Should include: AmazonEC2ContainerRegistryPowerUser

# Test ECR login manually on Jenkins EC2
ssh -i hm-eks-key.pem ubuntu@${JENKINS_IP}
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com
# Expected: Login Succeeded
```

---

### 5. HPA shows `<unknown>` targets

**Symptom:**
```
NAME          TARGETS           MINPODS   MAXPODS
backend-hpa   <unknown>/70%     2         5
```

**Diagnosis:**
```bash
kubectl top pods -n hm-shop
# If this fails: Metrics Server is not running
```

**Fix:**
```bash
# Check Metrics Server pods
kubectl get pods -n kube-system | grep metrics-server

# Reinstall if missing
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Wait 60 seconds then check HPA again
kubectl get hpa -n hm-shop
```

---

### 6. SonarQube Quality Gate fails

**Symptom:** Stage 1 fails with `QUALITY GATE STATUS: FAILED`

**Diagnosis:**
```bash
# Open SonarQube dashboard
# http://<JENKINS_IP>:9000/dashboard?id=hm-fashion-clone
# Look at the Issues tab for specific violations
```

**Fix:**
- Review code issues reported in the SonarQube dashboard
- Common issues: code smells, high cognitive complexity, missing test coverage
- To temporarily allow the pipeline to proceed: in SonarQube → Quality Gates → Conditions → raise the threshold or switch to a more lenient gate

---

### 7. Jenkins triggers infinite build loop

**Symptom:** After a successful pipeline run, Jenkins immediately starts another build. This keeps looping because Stage 6 (GitOps) commits updated image tags back to GitHub, which re-triggers the webhook.

**Why:** Jenkins does not natively honor the `[skip ci]` convention in commit messages — that is a GitHub Actions feature. The webhook fires on every push, including the one Jenkins itself makes.

**Fix:** Add a commit message check at the very top of the `pipeline` block in the `Jenkinsfile`:

```groovy
pipeline {
  agent any
  stages {
    stage('Check Skip CI') {
      steps {
        script {
          def commitMsg = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
          if (commitMsg.contains('[skip ci]')) {
            currentBuild.result = 'SUCCESS'
            error('Skipping CI — commit message contains [skip ci]')
          }
        }
      }
    }
    // ... rest of your stages
  }
}
```

This causes the pipeline to exit cleanly (not fail) whenever it detects its own tag-update commit, breaking the loop.

---

### 8. GitHub Webhook returns 404

**Symptom:** GitHub webhook delivery shows red ✗ with 404 response.

**Diagnosis:**
Check if Jenkins is reachable from GitHub (needs public IP, not localhost):
```bash
curl -I http://<JENKINS_IP>:8080/github-webhook/
# Expected: HTTP/1.1 200
```

**Fix:**
```bash
# Verify port 8080 is open in Jenkins security group
aws ec2 describe-security-groups --filters "Name=group-name,Values=hm-shop-jenkins-sg" --region ap-south-1 --query "SecurityGroups[0].IpPermissions"

# Verify Jenkins GitHub plugin is installed
# Jenkins → Manage Jenkins → Plugins → Installed → search "github"

# Verify webhook URL format (must end with /github-webhook/)
# Correct:   http://13.233.x.x:8080/github-webhook/
# Incorrect: http://13.233.x.x:8080/github-webhook  (no trailing slash)
```

---
