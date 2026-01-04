#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Kubernetes Auto-Deployment from GitHub Repo"
echo "============================================"
echo

read -p "🔗 Enter GitHub repository URL (HTTPS): " GITHUB_REPO_URL
read -s -p "🔑 Enter your GitHub Personal Access Token: " GITHUB_TOKEN
echo
read -p "🌿 Enter branch name (default: main): " GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}

# derive repo name for namespace + default path
REPO_NAME=$(basename -s .git "$GITHUB_REPO_URL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
NAMESPACE="$REPO_NAME"

DEFAULT_WORKDIR="./$REPO_NAME"
read -p "📁 Enter target working directory (default: ${DEFAULT_WORKDIR}): " WORKDIR
WORKDIR=${WORKDIR:-$DEFAULT_WORKDIR}

read -p "📝 Enter image tag (leave blank for random 5-digit): " IMAGE_TAG
if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG=$(printf "%05d" $(( RANDOM % 100000 )))
  echo "🔖 Using auto-generated tag: $IMAGE_TAG"
else
  echo "🔖 Using custom tag: $IMAGE_TAG"
fi



CLONE_URL=$(echo "$GITHUB_REPO_URL" | sed -E "s#https://#https://${GITHUB_TOKEN}@#")

echo "📥 Cloning repository (branch: $GIT_BRANCH)..."
rm -rf "$WORKDIR"
git clone --branch "$GIT_BRANCH" --single-branch "$CLONE_URL" "$WORKDIR" >/dev/null 2>&1 || {
  echo "❌ Failed to clone repo. Check PAT, URL, or branch name."
  exit 1
}
echo "✅ Repository cloned to $WORKDIR"
echo

# Create namespace (idempotent)
echo "🧭 Ensuring namespace exists..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

OUTPUT_DIR="k8s-output"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

echo "🔍 Searching for Dockerfiles..."
mapfile -t DOCKERFILES < <(find "$WORKDIR" -type f -iname "Dockerfile")

if [[ ${#DOCKERFILES[@]} -eq 0 ]]; then
  echo "❌ No Dockerfiles found. Exiting."
  exit 1
fi

echo "🧩 Found ${#DOCKERFILES[@]} Dockerfile(s)"
echo

create_config_and_secret() {
  local env_file="$1"
  local name="$2"

  local CONFIG_FILE="$OUTPUT_DIR/${name}-configmap.yaml"
  local SECRET_FILE="$OUTPUT_DIR/${name}-secret.yaml"

  echo "apiVersion: v1
kind: ConfigMap
metadata:
  name: ${name}-config
  namespace: $NAMESPACE
data:" > "$CONFIG_FILE"

  echo "apiVersion: v1
kind: Secret
metadata:
  name: ${name}-secret
  namespace: $NAMESPACE
type: Opaque
stringData:" > "$SECRET_FILE"

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    if [[ "$key" =~ (PASS|PASSWORD|TOKEN|SECRET|KEY) ]]; then
      echo "  $key: \"$value\"" >> "$SECRET_FILE"
    else
      echo "  $key: \"$value\"" >> "$CONFIG_FILE"
    fi
  done < "$env_file"

  echo "   📄 ConfigMap + Secret created for $name"
}

create_db_resources() {
  local dbtype="$1"
  local name="$2"
  local dbdir="$3"

  local DB_IMAGE=""

  case "$dbtype" in
    postgres|postgresql) DB_IMAGE="postgres:latest" ;;
    mysql) DB_IMAGE="mysql:latest" ;;
    mariadb) DB_IMAGE="mariadb:latest" ;;
    *) echo "⚠️ Unknown DB type '$dbtype' — skipping DB deployment"; return ;;
  esac

  local PVC_FILE="$OUTPUT_DIR/${name}-db-pvc.yaml"
  local DEPLOY_FILE="$OUTPUT_DIR/${name}-db-deployment.yaml"
  local SERVICE_FILE="$OUTPUT_DIR/${name}-db-service.yaml"

  cat > "$PVC_FILE" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}-db-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

  cat > "$DEPLOY_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}-db
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}-db
  template:
    metadata:
      labels:
        app: ${name}-db
    spec:
      containers:
      - name: db
        image: $DB_IMAGE
        envFrom:
        - secretRef:
            name: ${name}-secret
        - configMapRef:
            name: ${name}-config
        volumeMounts:
        - name: db-data
          mountPath: /var/lib/data
        - name: db-init
          mountPath: /docker-entrypoint-initdb.d
      volumes:
      - name: db-data
        persistentVolumeClaim:
          claimName: ${name}-db-pvc
      - name: db-init
        hostPath:
          path: $dbdir/init.sql
EOF

  cat > "$SERVICE_FILE" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${name}-db
  namespace: $NAMESPACE
spec:
  selector:
    app: ${name}-db
  ports:
  - port: 5432
    targetPort: 5432
EOF

  echo "🛢 Database resources created for $name ($dbtype)"
}

for df in "${DOCKERFILES[@]}"; do
  SERVICEDIR=$(dirname "$df")

  # Path relative to repo root
  REL_PATH="${SERVICEDIR#"$WORKDIR"/}"

  # If stripping failed, fallback to basename
  if [[ "$REL_PATH" == "$SERVICEDIR" || -z "$REL_PATH" ]]; then
    REL_PATH=$(basename "$SERVICEDIR")
  fi

  # Normalize → lowercase, replace invalid chars with -, collapse repeats, strip leading -
  SERVICE_NAME=$(echo "$REL_PATH" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's#[^a-z0-9._-]#-#g' \
    | sed 's/^-*//' \
    | sed 's/-\{2,\}/-/g')

  # Fallback if still empty
  [[ -z "$SERVICE_NAME" ]] && SERVICE_NAME="$REPO_NAME"

  echo "⚙️ Processing service: $SERVICE_NAME ($SERVICEDIR)"

  echo "🐳 Building Docker image..."
  
  IMAGE_NAME="$SERVICE_NAME:$IMAGE_TAG"
  docker build -t "$IMAGE_NAME" "$SERVICEDIR"


  ENVFILE="$SERVICEDIR/.env"
  INITSQL="$SERVICEDIR/init.sql"

  if [[ -f "$ENVFILE" ]]; then
    create_config_and_secret "$ENVFILE" "$SERVICE_NAME"
  fi

  DEPLOY_FILE="$OUTPUT_DIR/${SERVICE_NAME}-deployment.yaml"
  SERVICE_FILE="$OUTPUT_DIR/${SERVICE_NAME}-service.yaml"

  # Detect port from Dockerfile EXPOSE (first numeric port found)
  EXPOSED_PORT=$(grep -i '^expose' "$df" | head -n1 | grep -oE '[0-9]+' || true)

# Default if EXPOSE not present
if [[ -z "$EXPOSED_PORT" ]]; then
  EXPOSED_PORT=80
  echo "⚠️  No EXPOSE found — defaulting to port $EXPOSED_PORT"
else
  echo "🔌 Detected EXPOSE port: $EXPOSED_PORT"
fi

  # ... previous code ...

  cat > "$DEPLOY_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $SERVICE_NAME
  template:
    metadata:
      labels:
        app: $SERVICE_NAME
    spec:
      containers:
      - name: $SERVICE_NAME
        image: $SERVICE_NAME:$IMAGE_TAG
        ports:
        - containerPort: $EXPOSED_PORT
        envFrom:
        - configMapRef:
            name: ${SERVICE_NAME}-config
        - secretRef:
            name: ${SERVICE_NAME}-secret
EOF

  cat > "$SERVICE_FILE" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: $SERVICE_NAME
  ports:
  - port: $EXPOSED_PORT
    targetPort: $EXPOSED_PORT
EOF

  if [[ -f "$ENVFILE" && -f "$INITSQL" ]]; then
    DB_TYPE=$(grep -E '^(DATABASE_TYPE|DB_ENGINE|DB_TYPE|ENGINE)=' "$ENVFILE" | head -1 | cut -d= -f2 | tr '[:upper:]' '[:lower:]' || true)
    if [[ -n "${DB_TYPE:-}" ]]; then
      create_db_resources "$DB_TYPE" "$SERVICE_NAME" "$SERVICEDIR"
    else
      echo "ℹ️ .env found but DB type not detected — skipping DB"
    fi
  else
    echo "ℹ️ DB resources skipped (missing .env or init.sql)"
  fi

  echo
done

echo "📄 All manifests written to $OUTPUT_DIR"
echo
read -p "👀 Show manifests before applying? (y/n): " SHOW
if [[ "$SHOW" == "y" ]]; then
  less "$OUTPUT_DIR"/*.yaml
fi

read -p "🚀 Apply manifests to Kubernetes namespace '$NAMESPACE'? (y/n): " APPLY
if [[ "$APPLY" == "y" ]]; then
  kubectl apply -n "$NAMESPACE" -f "$OUTPUT_DIR"
  echo "🎉 Deployment complete!"
else
  echo "👍 Skipped applying resources."
fi
