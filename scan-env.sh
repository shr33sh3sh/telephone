#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-.}"
TAG="${2:-latest}"
PARENT_NAME="$(basename "$(realpath "$ROOT_DIR")")"
K8S_OUT_DIR="$ROOT_DIR/k8s-manifests"

mkdir -p "$K8S_OUT_DIR"

echo "📦 Project: $PARENT_NAME"
echo

############################################
# Helper: trim whitespace
############################################
trim() {
  awk '{$1=$1};1'
}

############################################
# 🎯 NAMESPACE SECTION — Create namespace
############################################
# Make namespace DNS-1123 safe
NAMESPACE="$(echo "$PARENT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
NAMESPACE="${NAMESPACE##-}"
NAMESPACE="${NAMESPACE%%-}"
[[ -z "$NAMESPACE" ]] && NAMESPACE="app-namespace"

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
  # PVC
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
      storage: 10Gi
EOF

  ############################################
  # Postgres Deployment
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
        envFrom:
        - configMapRef:
            name: ${PARENT_NAME}-config
        - secretRef:
            name: ${PARENT_NAME}-secret
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
        - name: init-script
          mountPath: /docker-entrypoint-initdb.d
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

fi

############################################
# 🔍 Scan for .env files
############################################
echo "🔍 Scanning for .env files..."
mapfile -t ENV_FILES < <(find "$ROOT_DIR" -type f -iname ".env*" ! -iname "*.example")

CM_FILE="$K8S_OUT_DIR/config.yaml"
SEC_FILE="$K8S_OUT_DIR/secret.yaml"

cat > "$CM_FILE" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PARENT_NAME}-config
  namespace: $NAMESPACE
data:
EOF

cat > "$SEC_FILE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${PARENT_NAME}-secret
  namespace: $NAMESPACE
type: Opaque
data:
EOF

if [[ ${#ENV_FILES[@]} -gt 0 ]]; then
  for ENV_FILE in "${ENV_FILES[@]}"; do
    while IFS='=' read -r KEY VALUE || [[ -n "$KEY" ]]; do
      KEY="$(echo "$KEY" | trim)"
      [[ -z "$KEY" ]] && continue
      [[ "$KEY" =~ ^# ]] && continue

      VALUE="${VALUE:-}"
      VALUE="$(echo "$VALUE" | trim)"

      if [[ "$KEY" =~ (PASS|PASSWORD|TOKEN|SECRET|KEY|USER) ]]; then
        B64=$(printf "%s" "$VALUE" | base64 -w0 2>/dev/null || printf "%s" "$VALUE" | base64)
        echo "  $KEY: $B64" >> "$SEC_FILE"
      else
        echo "  $KEY: \"$VALUE\"" >> "$CM_FILE"
      fi
    done < "$ENV_FILE"
  done
fi

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
echo "🐳 Building Docker images + generating manifests..."
echo

for FILE in "${DOCKERFILES[@]}"; do
  DIR_PATH="$(dirname "$FILE")"
  DIR_NAME="$(basename "$DIR_PATH")"
  [[ "$DIR_PATH" == "$ROOT_DIR" ]] && DIR_NAME="root"

  IMAGE_NAME="${PARENT_NAME}-${DIR_NAME}:${TAG}"

  docker build -f "$FILE" -t "$IMAGE_NAME" "$DIR_PATH"

  PORT=$(grep -i '^expose ' "$FILE" | awk '{print $2}' | head -1 || true)
  [[ -z "${PORT:-}" ]] && PORT=80

  DEPLOY_NAME="${PARENT_NAME}-${DIR_NAME}-deployment"
  SERVICE_NAME="${PARENT_NAME}-${DIR_NAME}-service"

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
      app: ${PARENT_NAME}-${DIR_NAME}
  template:
    metadata:
      labels:
        app: ${PARENT_NAME}-${DIR_NAME}
    spec:
      containers:
      - name: ${DIR_NAME}
        image: $IMAGE_NAME
        ports:
        - containerPort: $PORT
        envFrom:
        - configMapRef:
            name: ${PARENT_NAME}-config
        - secretRef:
            name: ${PARENT_NAME}-secret
EOF

  cat > "$K8S_OUT_DIR/${DIR_NAME}-service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
spec:
  selector:
    app: ${PARENT_NAME}-${DIR_NAME}
  ports:
  - port: $PORT
    targetPort: $PORT
    protocol: TCP
  type: ClusterIP
EOF

done

echo "🎉 Finished building images + generating Kubernetes manifests."
echo "📂 Output in: $K8S_OUT_DIR"
echo
echo "⚡ Deploy using:"
echo "   kubectl apply -f k8s-manifests/"
echo
echo "⭐ Then select namespace:"
echo "   kubectl config set-context --current --namespace=$NAMESPACE"
