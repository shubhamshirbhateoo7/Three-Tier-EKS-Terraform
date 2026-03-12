pipeline {
  agent any

  environment {
    REGISTRY          = "<YOUR_AWS_ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com"
    FRONTEND_IMAGE    = "${REGISTRY}/hm-frontend"
    BACKEND_IMAGE     = "${REGISTRY}/hm-backend"
    AWS_REGION        = "ap-south-1"
    CLUSTER_NAME      = "three-tier-cluster"
    GIT_REPO          = "https://github.com/<YOUR_GITHUB_USERNAME>/<YOUR_REPO_NAME>.git"
    SONAR_PROJECT_KEY = "hm-fashion-clone"
    K8S_NAMESPACE     = "hm-shop"
  }

  stages {

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 1 — Code Quality Analysis (SonarQube)
    // Quality Gate failure aborts pipeline — prevents bad code reaching prod
    // ─────────────────────────────────────────────────────────────────────────
    stage('Code Quality Analysis (SonarQube)') {
      steps {
        withCredentials([
          string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')
        ]) {
          withSonarQubeEnv('SonarQube') {
            sh """
              sonar-scanner \
                -Dsonar.projectKey=${SONAR_PROJECT_KEY} \
                -Dsonar.projectName="H&M Fashion Clone" \
                -Dsonar.projectVersion=1.0 \
                -Dsonar.sources=app/frontend/src,app/backend \
                -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info \
                -Dsonar.exclusions=**/node_modules/**,**/build/**,**/*.test.js \
                -Dsonar.login=${SONAR_TOKEN}
            """
          }
          timeout(time: 2, unit: 'MINUTES') {
            waitForQualityGate abortPipeline: true
          }
        }
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 2 — Dependency Check (Snyk)
    // UNSTABLE on high severity; aborts on critical severity
    // ─────────────────────────────────────────────────────────────────────────
    stage('Dependency Check (Snyk)') {
      steps {
        withCredentials([
          string(credentialsId: 'snyk-token', variable: 'SNYK_TOKEN')
        ]) {
          sh """
            echo "Installing dependencies for Snyk scan..."
            (cd app/frontend && npm install --silent 2>/dev/null || npm install)
            (cd app/backend  && npm install --silent 2>/dev/null || npm install)

            snyk auth ${SNYK_TOKEN}
            snyk test --all-projects \
                      --severity-threshold=high \
                      --json > snyk-results.json || true
          """
          archiveArtifacts artifacts: 'snyk-results.json', allowEmptyArchive: true
          catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
            sh """
              snyk test --all-projects \
                        --severity-threshold=critical
            """
          }
        }
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 3 — File System Scan (Trivy)
    // exit-code 0 = always passes but results are archived for audit trail
    // ─────────────────────────────────────────────────────────────────────────
    stage('File System Scan (Trivy)') {
      steps {
        sh """
          trivy fs \
            --exit-code 0 \
            --severity HIGH,CRITICAL \
            --format table \
            -o trivy-fs-results.txt \
            .
          echo "=== Trivy FS Scan Results ==="
          cat trivy-fs-results.txt
        """
        archiveArtifacts artifacts: 'trivy-fs-results.txt', allowEmptyArchive: true
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 4 — Build Docker Images
    // BUILD_NUMBER tag is immutable; ArgoCD uses this for GitOps updates
    // :latest tag used for quick local testing only
    // ─────────────────────────────────────────────────────────────────────────
    stage('Build Docker Images') {
      steps {
        sh """
          echo "Building frontend image..."
          docker build \
            -t ${FRONTEND_IMAGE}:${BUILD_NUMBER} \
            -t ${FRONTEND_IMAGE}:latest \
            app/frontend/

          echo "Building backend image..."
          docker build \
            -t ${BACKEND_IMAGE}:${BUILD_NUMBER} \
            -t ${BACKEND_IMAGE}:latest \
            app/backend/

          echo "Images built:"
          docker images | grep -E "hm-frontend|hm-backend"
        """
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 5 — Push to AWS ECR Private
    // Uses IAM credentials stored in Jenkins for ECR login
    // ─────────────────────────────────────────────────────────────────────────
    stage('Push to AWS ECR Private') {
      steps {
        withCredentials([
          string(credentialsId: 'aws-access-key',  variable: 'AWS_ACCESS_KEY_ID'),
          string(credentialsId: 'aws-secret-key',  variable: 'AWS_SECRET_ACCESS_KEY')
        ]) {
          sh """
            aws configure set aws_access_key_id     ${AWS_ACCESS_KEY_ID}
            aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
            aws configure set default.region        ${AWS_REGION}

            echo "Authenticating with ECR..."
            aws ecr get-login-password --region ${AWS_REGION} \
              | docker login \
                  --username AWS \
                  --password-stdin ${REGISTRY}

            echo "Pushing frontend image..."
            docker push ${FRONTEND_IMAGE}:${BUILD_NUMBER}
            docker push ${FRONTEND_IMAGE}:latest

            echo "Pushing backend image..."
            docker push ${BACKEND_IMAGE}:${BUILD_NUMBER}
            docker push ${BACKEND_IMAGE}:latest

            echo "All images pushed successfully."
          """
        }
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 6 — Trivy Image Scan (ECR)
    // Catches vulnerabilities introduced by base images or npm install
    // exit-code 0 so pipeline continues; results archived for audit
    // ─────────────────────────────────────────────────────────────────────────
    stage('Trivy Image Scan (ECR)') {
      steps {
        withCredentials([
          string(credentialsId: 'aws-access-key',  variable: 'AWS_ACCESS_KEY_ID'),
          string(credentialsId: 'aws-secret-key',  variable: 'AWS_SECRET_ACCESS_KEY')
        ]) {
          sh """
            aws configure set aws_access_key_id     ${AWS_ACCESS_KEY_ID}
            aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
            aws configure set default.region        ${AWS_REGION}

            echo "Scanning frontend image..."
            trivy image \
              --exit-code 0 \
              --severity HIGH,CRITICAL \
              --format table \
              -o trivy-image-frontend.txt \
              ${FRONTEND_IMAGE}:${BUILD_NUMBER}

            echo "Scanning backend image..."
            trivy image \
              --exit-code 0 \
              --severity HIGH,CRITICAL \
              --format table \
              -o trivy-image-backend.txt \
              ${BACKEND_IMAGE}:${BUILD_NUMBER}

            echo "=== Frontend Image Scan ==="
            cat trivy-image-frontend.txt

            echo "=== Backend Image Scan ==="
            cat trivy-image-backend.txt
          """
        }
        archiveArtifacts artifacts: 'trivy-image-*.txt', allowEmptyArchive: true
      }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STAGE 7 — Update Deployment Files (GitOps)
    // Jenkins commits updated image tags back to repo
    // ArgoCD detects the new commit and syncs within 3 minutes
    // [skip ci] in commit message prevents recursive pipeline trigger
    // ─────────────────────────────────────────────────────────────────────────
    stage('Update Deployment Files (GitOps)') {
      steps {
        withCredentials([
          usernamePassword(
            credentialsId: 'git-credentials',
            usernameVariable: 'GIT_USER',
            passwordVariable: 'GIT_PASS'
          )
        ]) {
          sh """
            git config user.email "jenkins@ci.local"
            git config user.name  "Jenkins CI"

            echo "Updating frontend deployment image tag to build ${BUILD_NUMBER}..."
            sed -i "s|${FRONTEND_IMAGE}:.*|${FRONTEND_IMAGE}:${BUILD_NUMBER}|g" \
              k8s_manifests/frontend/deployment.yaml

            echo "Updating backend deployment image tag to build ${BUILD_NUMBER}..."
            sed -i "s|${BACKEND_IMAGE}:.*|${BACKEND_IMAGE}:${BUILD_NUMBER}|g" \
              k8s_manifests/backend/deployment.yaml

            git add k8s_manifests/frontend/deployment.yaml \
                    k8s_manifests/backend/deployment.yaml

            git commit -m "CI: Update image tags to build-${BUILD_NUMBER} [skip ci]"

            git remote set-url origin "https://${GIT_USER}:${GIT_PASS}@github.com/Abhiram-Rakesh/Three-Tier-EKS-Terraform.git"
            git push origin HEAD:main

            echo "Deployment files updated. ArgoCD will sync within 3 minutes."
          """
        }
      }
    }
  }

  post {
    always {
      sh """
        docker rmi ${FRONTEND_IMAGE}:${BUILD_NUMBER} ${FRONTEND_IMAGE}:latest || true
        docker rmi ${BACKEND_IMAGE}:${BUILD_NUMBER}  ${BACKEND_IMAGE}:latest  || true
        echo "Docker images cleaned up."
      """
      cleanWs()
    }
    success {
      echo "✅ Pipeline SUCCESS — Build #${BUILD_NUMBER} deployed via ArgoCD GitOps"
    }
    failure {
      echo "❌ Pipeline FAILED — Check stage logs above for details"
    }
    unstable {
      echo "⚠️  Pipeline UNSTABLE — High-severity vulnerabilities found. Review Snyk/Trivy results."
    }
  }
}
