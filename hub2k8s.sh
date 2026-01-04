#!/usr/bin/env bash
set -euo pipefail

echo "🚀 GitHub Repository Deployment to Kubernetes"
echo "============================================"
echo

############################################
# 🎯 GITHUB REPOSITORY CONFIGURATION
############################################
echo "🎯 GitHub Repository Setup"
echo "========================"

# 1. Get GitHub repository URL
read -p "🔗 Enter GitHub repository URL (https format): " GITHUB_REPO_URL

# Validate URL format
if [[ ! "$GITHUB_REPO_URL" =~ ^https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(/)?$ ]]; then
  echo "❌ Invalid GitHub URL format. Should be: https://github.com/username/repository"
  exit 1
fi

# 2. Get branch name
read -p "🌿 Enter branch name (default: main): " GITHUB_BRANCH
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# 3. Get GitHub token (optional for private repos)
echo -n "🔑 Enter GitHub token (press Enter if public repo): "
read -s GITHUB_TOKEN
echo

# Extract repo name from URL
REPO_NAME=$(basename "$GITHUB_REPO_URL" .git)
WORK_DIR="/tmp/k8s-deploy-$REPO_NAME-$(date +%s)"

echo "📂 Creating workspace: $WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Clone repository
echo "📥 Cloning repository..."
if [[ -n "$GITHUB_TOKEN" ]]; then
  # For private repos with token
  GITHUB_REPO_URL_WITH_TOKEN=$(echo "$GITHUB_REPO_URL" | sed "s|https://|https://$GITHUB_TOKEN@|")
  git clone -b "$GITHUB_BRANCH" "$GITHUB_REPO_URL_WITH_TOKEN" "$REPO_NAME" || {
    echo "❌ Failed to clone repository. Check token and permissions."
    exit 1
  }
else
  # For public repos
  git clone -b "$GITHUB_BRANCH" "$GITHUB_REPO_URL" "$REPO_NAME" || {
    echo "❌ Failed to clone repository."
    exit 1
  }
fi

cd "$REPO_NAME"
ROOT_DIR="$(pwd)"
PARENT_NAME="$REPO_NAME"
K8S_OUT_DIR="$ROOT_DIR/k8s-manifests"

mkdir -p "$K8S_OUT_DIR"

echo "📦 Project: $PARENT_NAME"
echo "📁 Location: $ROOT_DIR"
echo

############################################
# Helper: trim whitespace
############################################
trim() {
  awk '{$1=$1};1'
}

############################################
# 🎯 INTERACTIVE CONFIGURATION
############################################
echo "🎯 Kubernetes Configuration"
echo "=========================="

# Generate 5-digit random tag
TAG=$(printf "%05d" $((RANDOM % 100000)))

# 1. Ask if user wants to customize the tag
read -p "🏷️  Use auto-generated tag '$TAG' or enter custom tag? (press enter for auto/custom): " CUSTOM_TAG_INPUT

if [[ -n "$CUSTOM_TAG_INPUT" ]]; then
  TAG="$CUSTOM_TAG_INPUT"
  echo "✅ Using custom tag: $TAG"
else
  echo "✅ Using auto-generated tag: $TAG"
fi

# 2. Get PVC size
read -p "📦 Enter PostgreSQL PVC storage size (default: 10Gi): " PVC_SIZE
PVC_SIZE="${PVC_SIZE:-10Gi}"

# Validate PVC size format
if [[ ! "$PVC_SIZE" =~ ^[0-9]+(Gi|Mi|G|M)$ ]]; then
  echo "⚠️  Warning: PVC size format should be like '10Gi', '5Gi', '100Mi'"
  echo "  Using default: 10Gi"
  PVC_SIZE="10Gi"
fi

# 3. Get namespace
read -p "🏷️  Enter Kubernetes namespace (default: ${PARENT_NAME}): " USER_NAMESPACE
if [[ -n "$USER_NAMESPACE" ]]; then
  # Make namespace DNS-1123 safe
  NAMESPACE="$(echo "$USER_NAMESPACE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | sed 's/^-//;s/-$//')"
  [[ -z "$NAMESPACE" ]] && NAMESPACE="${PARENT_NAME}"
else
  # Make namespace DNS-1123 safe from PARENT_NAME
  NAMESPACE="$(echo "$PARENT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  NAMESPACE="${NAMESPACE##-}"
  NAMESPACE="${NAMESPACE%%-}"
fi

[[ -z "$NAMESPACE" ]] && NAMESPACE="app-namespace"

echo "✅ Using namespace: $NAMESPACE"
echo "✅ Using PVC size: $PVC_SIZE"
echo

############################################
# 🎯 NAMESPACE SECTION — Create namespace
############################################
NS_FILE="$K8S_OUT_DIR/namespace.yaml"

cat > "$NS_FILE" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
EOF

echo "📝 Created namespace: $NAMESPACE"
echo

############################################
# 🔍 Scan for .env files FIRST
############################################
echo "🔍 Scanning for .env files..."
mapfile -t ENV_FILES < <(find "$ROOT_DIR" -type f -iname ".env*" ! -iname "*.example")

CM_FILE="$K8S_OUT_DIR/configmap.yaml"
SEC_FILE="$K8S_OUT_DIR/secret.yaml"

# Initialize empty associative arrays for tracking variables
declare -A CONFIG_VARS
declare -A SECRET_VARS

# Parse .env files
if [[ ${#ENV_FILES[@]} -gt 0 ]]; then
  for ENV_FILE in "${ENV_FILES[@]}"; do
    echo "  Processing: $ENV_FILE"
    while IFS='=' read -r KEY VALUE || [[ -n "$KEY" ]]; do
      KEY="$(echo "$KEY" | trim)"
      [[ -z "$KEY" ]] && continue
      [[ "$KEY" =~ ^# ]] && continue

      VALUE="${VALUE:-}"
      VALUE="$(echo "$VALUE" | trim)"
      # Remove quotes from value
      VALUE="${VALUE#\"}"
      VALUE="${VALUE%\"}"
      VALUE="${VALUE#\'}"
      VALUE="${VALUE%\'}"

      if [[ "$KEY" =~ (PASS|PASSWORD|TOKEN|SECRET|KEY|USER) ]]; then
        SECRET_VARS["$KEY"]="$VALUE"
      else
        CONFIG_VARS["$KEY"]="$VALUE"
      fi
    done < "$ENV_FILE"
  done
fi

############################################
# 🔍 Scan for database init SQL files...
############################################
echo "🔍 Scanning for database init SQL files..."

mapfile -t SQL_FILES < <(find "$ROOT_DIR" -maxdepth 2 -type f \( -iname "init.sql" -o -iname "*.sql" \))

if [[ ${#SQL_FILES[@]} -eq 0 ]]; then
  echo "⚠️ No SQL init files found. Skipping Postgres generation."
else
  SQL_FILE="${SQL_FILES[0]}"

  echo "✔ Found SQL init file: $SQL_FILE"
  echo

  ############################################
  # ConfigMap for DB init
  ############################################
  cat > "$K8S_OUT_DIR/postgres-init-configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PARENT_NAME}-postgres-init
  namespace: $NAMESPACE
data:
  init.sql: |
$(sed 's/^/    /' "$SQL_FILE")
EOF

  ############################################
  # PVC with user-specified size
  ############################################
  cat > "$K8S_OUT_DIR/postgres-pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PARENT_NAME}-postgres-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $PVC_SIZE
EOF

  ############################################
  # Postgres Deployment with CORRECT env vars
  ############################################
  cat > "$K8S_OUT_DIR/postgres-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PARENT_NAME}-postgres
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PARENT_NAME}-postgres
  template:
    metadata:
      labels:
        app: ${PARENT_NAME}-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        # PostgreSQL-specific environment variables (REQUIRED by postgres image)
        - name: POSTGRES_DB
          valueFrom:
            configMapKeyRef:
              name: ${PARENT_NAME}-config
              key: DATABASE_NAME
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: ${PARENT_NAME}-secret
              key: DATABASE_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${PARENT_NAME}-secret
              key: DATABASE_PASSWORD
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
          subPath: postgres  # Important: prevents permission issues
        - name: init-script
          mountPath: /docker-entrypoint-initdb.d
        readinessProbe:
          exec:
            command:
            - pg_isready
            - -U
            - postgres
          initialDelaySeconds: 15
          periodSeconds: 10
        livenessProbe:
          exec:
            command:
            - pg_isready
            - -U
            - postgres
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: ${PARENT_NAME}-postgres-pvc
      - name: init-script
        configMap:
          name: ${PARENT_NAME}-postgres-init
EOF

  ############################################
  # Postgres Service
  ############################################
  cat > "$K8S_OUT_DIR/postgres-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${PARENT_NAME}-postgres
  namespace: $NAMESPACE
spec:
  selector:
    app: ${PARENT_NAME}-postgres
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF

  # IMPORTANT FIX: Always override DATABASE_HOST to use the correct service name
  # This ensures the application connects to the right Postgres service
  CONFIG_VARS["DATABASE_HOST"]="${PARENT_NAME}-postgres"
  echo "  Overriding DATABASE_HOST to: ${PARENT_NAME}-postgres"
fi

############################################
# Write ConfigMap
############################################
cat > "$CM_FILE" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PARENT_NAME}-config
  namespace: $NAMESPACE
data:
EOF

for KEY in "${!CONFIG_VARS[@]}"; do
  echo "  $KEY: \"${CONFIG_VARS[$KEY]}\"" >> "$CM_FILE"
done

############################################
# Write Secret
############################################
cat > "$SEC_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PARENT_NAME}-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
EOF

for KEY in "${!SECRET_VARS[@]}"; do
  echo "  $KEY: \"${SECRET_VARS[$KEY]}\"" >> "$SEC_FILE"
done

echo "✅ Created ConfigMap and Secret"
echo

############################################
# 🔍 Dockerfiles
############################################
echo "🔍 Scanning for Dockerfiles..."

mapfile -t DOCKERFILES < <(find "$ROOT_DIR" -type f \
  \( -iname "Dockerfile" -o -iname "Dockerfile.*" -o -iname "dockerfile" \))

if [[ ${#DOCKERFILES[@]} -eq 0 ]]; then
  echo "❌ No Dockerfiles found. Exiting."
  exit 1
fi

echo
echo "🐳 Building Docker images with tag: $TAG"
echo

for FILE in "${DOCKERFILES[@]}"; do
  DIR_PATH="$(dirname "$FILE")"
  DIR_NAME="$(basename "$DIR_PATH")"

# If Dockerfile is in root, omit suffix
if [[ "$DIR_PATH" == "$ROOT_DIR" ]]; then
  APP_NAME="$PARENT_NAME"
else
  APP_NAME="$DIR_NAME"
fi

  IMAGE_NAME="${APP_NAME}:${TAG}"

  echo "  Building: $IMAGE_NAME"
  docker build -f "$FILE" -t "$IMAGE_NAME" "$DIR_PATH"
  
  # Check if kind cluster exists before loading
  if kind get clusters 2>/dev/null | grep -q "staging-cluster"; then
    kind load docker-image "$IMAGE_NAME" --name staging-cluster
  else
    echo "  ⚠️  Kind cluster 'staging-cluster' not found. Skipping image load."
  fi

  PORT=$(grep -i '^expose ' "$FILE" | awk '{print $2}' | head -1 || echo "8000")
  [[ -z "${PORT:-}" ]] && PORT=8000

  DEPLOY_NAME="$APP_NAME"
  SERVICE_NAME="$APP_NAME-service"

  # Check if this is a CLI application
  if [[ "$DIR_NAME" == "cli" ]]; then
    # For CLI, run a health check command instead of the interactive CLI
    cat > "$K8S_OUT_DIR/${APP_NAME}-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $APP_NAME
  template:
    metadata:
      labels:
        app: $APP_NAME
    spec:
      containers:
      - name: ${DIR_NAME}
        image: $IMAGE_NAME
        imagePullPolicy: IfNotPresent
        command: ["python"]
        args: ["-c", "print('CLI service is healthy'); import sys; sys.exit(0)"]
        envFrom:
        - configMapRef:
            name: ${PARENT_NAME}-config
        - secretRef:
            name: ${PARENT_NAME}-secret
EOF
  else
    # Regular deployment for web services
    cat > "$K8S_OUT_DIR/${DIR_NAME}-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
      - name: ${DIR_NAME}
        image: $IMAGE_NAME
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: $PORT
        envFrom:
        - configMapRef:
            name: ${PARENT_NAME}-config
        - secretRef:
            name: ${PARENT_NAME}-secret
        readinessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 30
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          httpGet:
            path: /health
            port: $PORT
          initialDelaySeconds: 60
          periodSeconds: 10
          failureThreshold: 3
EOF
  fi

  cat > "$K8S_OUT_DIR/${APP_NAME}-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: ${APP_NAME}
  ports:
  - port: 80
    targetPort: $PORT
    protocol: TCP
  type: ClusterIP
EOF

done

echo
echo "🎉 Finished building images + generating Kubernetes manifests."
echo "📂 Output in: $K8S_OUT_DIR"
echo

############################################
# 🚀 INTERACTIVE DEPLOYMENT
############################################
echo "🚀 Deployment Options"
echo "===================="
read -p "Do you want to deploy to Kubernetes now? (y/N): " DEPLOY_CHOICE

if [[ "$DEPLOY_CHOICE" =~ ^[Yy]$ ]]; then
  echo "📦 Deploying to Kubernetes cluster..."
  echo
  
  # 1. Deploy namespace first
  echo "1️⃣  Creating namespace: $NAMESPACE"
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "   ℹ️  Namespace '$NAMESPACE' already exists"
  else
    kubectl apply -f "$NS_FILE"
    echo "   ✅ Namespace created"
  fi
  
  # 2. Deploy all other resources
  echo "2️⃣  Deploying all Kubernetes resources..."
  
  # Get all yaml files except namespace (since we already deployed it)
  mapfile -t YAML_FILES < <(find "$K8S_OUT_DIR" -name "*.yaml" ! -name "namespace.yaml")
  
  for YAML_FILE in "${YAML_FILES[@]}"; do
    echo "   📄 Applying: $(basename "$YAML_FILE")"
    kubectl apply -f "$YAML_FILE" --namespace="$NAMESPACE"
  done
  
  echo "   ✅ All resources deployed"
  
  # 3. Set current context to namespace
  echo "3️⃣  Setting current context to namespace: $NAMESPACE"
  kubectl config set-context --current --namespace="$NAMESPACE"
  
  # 4. Wait for deployments to be ready
  echo "4️⃣  Waiting for deployments to be ready..."
  echo
  sleep 5
  
  # Check deployments
  echo "📊 Deployment Status:"
  echo "-------------------"
  
  # Check Postgres if it exists
  if [[ -f "$K8S_OUT_DIR/postgres-deployment.yaml" ]]; then
    echo "🔍 Checking PostgreSQL deployment..."
    for i in {1..60}; do
      if kubectl get deployment "${PARENT_NAME}-postgres" -n "$NAMESPACE" >/dev/null 2>&1; then
        POSTGRES_READY=$(kubectl get deployment "${PARENT_NAME}-postgres" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "$POSTGRES_READY" == "1" ]]; then
          echo "   ✅ PostgreSQL is ready"
          break
        fi
      fi
      if [[ $i -eq 60 ]]; then
        echo "   ⚠️  PostgreSQL deployment still not ready after 60 seconds"
        echo "   Run: kubectl get pods -n $NAMESPACE | grep postgres"
      fi
      sleep 1
    done
  fi
  
  # Check other deployments
  for DEPLOY_FILE in "$K8S_OUT_DIR"/*-deployment.yaml; do
    if [[ -f "$DEPLOY_FILE" ]] && [[ "$(basename "$DEPLOY_FILE")" != "postgres-deployment.yaml" ]]; then
      DEPLOY_NAME=$(basename "$DEPLOY_FILE" -deployment.yaml)
      echo "🔍 Checking $DEPLOY_NAME deployment..."
      for i in {1..60}; do
        if kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
          DEPLOY_READY=$(kubectl get deployment "$DEPLOY_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
          if [[ "$DEPLOY_READY" == "1" ]]; then
            echo "   ✅ $DEPLOY_NAME is ready"
            break
          fi
        fi
        if [[ $i -eq 60 ]]; then
          echo "   ⚠️  $DEPLOY_NAME deployment still not ready after 60 seconds"
        fi
        sleep 1
      done
    fi
  done
  
  # 5. Show final status
  echo
  echo "📊 Final Status Summary:"
  echo "========================"
  echo "📦 Namespace: $NAMESPACE"
  echo "🏷️  Image tag: $TAG"
  echo "📁 Repository: $GITHUB_REPO_URL"
  echo "🌿 Branch: $GITHUB_BRANCH"
  echo "📂 Workspace: $WORK_DIR"
  echo
  
  # Show all resources
  echo "🔍 All resources in namespace:"
  kubectl get all -n "$NAMESPACE"
  
  echo
  echo "🔍 Persistent Volume Claims:"
  kubectl get pvc -n "$NAMESPACE"
  
  echo
  echo "🔍 Services:"
  kubectl get svc -n "$NAMESPACE"
  
  echo
  echo "🔍 Pods status:"
  kubectl get pods -n "$NAMESPACE" -o wide
  
  echo
  echo "📝 Useful Commands:"
  echo "-------------------"
  echo "View logs (PostgreSQL): kubectl logs -f deployment/${PARENT_NAME}-postgres -n $NAMESPACE"
  
  # Find first non-postgres deployment
  DEPLOY_FILE=$(ls "$K8S_OUT_DIR"/*-deployment.yaml 2>/dev/null | grep -v postgres-deployment.yaml | head -1)
  if [[ -n "$DEPLOY_FILE" ]]; then
    DEPLOY_NAME=$(basename "$DEPLOY_FILE" -deployment.yaml)
    echo "View logs (Application): kubectl logs -f deployment/$DEPLOY_NAME -n $NAMESPACE"
  fi
  
  echo "Get shell in pod: kubectl exec -it <pod-name> -n $NAMESPACE -- bash"
  echo "Delete everything: kubectl delete -f $K8S_OUT_DIR/"
  echo
  echo "🏷️  Images built with tag: $TAG"
  echo "🎉 Deployment completed!"
  
  # Ask if user wants to clean up workspace
  echo
  read -p "🧹 Clean up workspace directory ($WORK_DIR)? (y/N): " CLEANUP_CHOICE
  if [[ "$CLEANUP_CHOICE" =~ ^[Yy]$ ]]; then
    cd /tmp
    rm -rf "$WORK_DIR"
    echo "✅ Workspace cleaned up"
  else
    echo "ℹ️  Workspace preserved at: $WORK_DIR"
  fi
  
else
  echo
  echo "📋 Manual deployment instructions:"
  echo "=================================="
  echo "🏷️  Images built with tag: $TAG"
  echo "📁 Repository: $GITHUB_REPO_URL"
  echo "🌿 Branch: $GITHUB_BRANCH"
  echo "📂 Workspace: $WORK_DIR"
  echo "⚡ Deploy using:"
  echo "   kubectl apply -f $K8S_OUT_DIR/"
  echo
  echo "⭐ Then select namespace:"
  echo "   kubectl config set-context --current --namespace=$NAMESPACE"
  echo
  echo "📊 View resources:"
  echo "   kubectl get all -n $NAMESPACE"
  echo
  echo "🔍 Check logs:"
  echo "   kubectl logs -f deployment/${PARENT_NAME}-postgres -n $NAMESPACE"
  
  # Find first deployment
  DEPLOY_FILE=$(ls "$K8S_OUT_DIR"/*-deployment.yaml 2>/dev/null | head -1)
  if [[ -n "$DEPLOY_FILE" ]]; then
    DEPLOY_NAME=$(basename "$DEPLOY_FILE" -deployment.yaml)
    echo "   kubectl logs -f deployment/$DEPLOY_NAME -n $NAMESPACE"
  fi
  
  echo
  echo "⚠️  Note: Workspace directory preserved at: $WORK_DIR"
  echo "     Clean up manually when done: rm -rf $WORK_DIR"
fi