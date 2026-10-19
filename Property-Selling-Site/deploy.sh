#!/usr/bin/env bash
# deploy.sh - builds the whole UrbanHive stack in four namespaces.
#   ./deploy.sh                    apply everything as cluster-admin
#   AS_USERS=1 ./deploy.sh         apply each component with its own user's kubeconfig
#   RETAIN_VOLUMES=0 ./deploy.sh   do not mark the new volumes as Retain
# Safe to re-run: applies are idempotent and existing Secrets are never overwritten.
set -euo pipefail
cd "$(dirname "$0")"

AS_USERS="${AS_USERS:-0}"
RETAIN_VOLUMES="${RETAIN_VOLUMES:-1}"

NS_FRONTEND=urban-hive-frontend
NS_BACKEND=urban-hive-backend
NS_POSTGRES=urban-hive-postgres
NS_MINIO=urban-hive-minio

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# apply_as <user> <file>...  : apply files as that component's user (or as admin)
apply_as() {
  local user=$1; shift
  local kc=() f
  if [ "$AS_USERS" = "1" ]; then
    kc=(--kubeconfig "rbac/users/$user/$user.kubeconfig")
  fi
  for f in "$@"; do
    [ -f "$f" ] || die "missing file: $f"
    kubectl ${kc[@]+"${kc[@]}"} apply -f "$f"
  done
}

# ensure_secret <namespace> <secret-name> <KEY>... : values come from variables of the same name
ensure_secret() {
  local ns=$1 name=$2; shift 2
  local args=() k
  if kubectl get secret "$name" -n "$ns" >/dev/null 2>&1; then
    echo "  secret $ns/$name already exists - keeping it"
    return
  fi
  for k in "$@"; do
    [ -n "${!k:-}" ] || die "secrets.env has no value for $k (needed for $ns/$name)"
    args+=(--from-literal="$k=${!k}")
  done
  kubectl create secret generic "$name" -n "$ns" "${args[@]}"
  echo "  secret $ns/$name created"
}

wait_ready() { kubectl rollout status "$1" -n "$2" --timeout=300s; }

# retain_pv <namespace> <pvc> : keep the volume's data if the PVC is ever deleted
retain_pv() {
  local pv="" i
  [ "$RETAIN_VOLUMES" = "1" ] || return 0
  for i in $(seq 1 30); do
    pv=$(kubectl get pvc "$2" -n "$1" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
    [ -n "$pv" ] && break
    sleep 2
  done
  [ -n "$pv" ] || die "PVC $1/$2 did not get a volume"
  kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
  echo "  $pv is now Retain"
}

if [ -f secrets.env ]; then set -a; . ./secrets.env; set +a; fi

step "Pre-flight checks"
command -v kubectl >/dev/null || die "kubectl is not installed"
kubectl cluster-info >/dev/null 2>&1 || die "cannot reach the cluster - check your kubeconfig"
[ "$(kubectl auth can-i create namespaces 2>/dev/null)" = "yes" ] || die "run this as cluster-admin"
if [ "$AS_USERS" = "1" ]; then
  for u in f-user b-user p-user m-user; do
    [ -f "rbac/users/$u/$u.kubeconfig" ] || die "AS_USERS=1 but rbac/users/$u/$u.kubeconfig is missing"
  done
fi

step "1/8 Namespaces"
[ -f rbac/namespaces.yaml ] || die "rbac/namespaces.yaml not found"
kubectl apply -f rbac/namespaces.yaml

step "2/8 Roles and RoleBindings"
ls rbac/access/*.yaml >/dev/null 2>&1 || die "no files in rbac/access/"
for f in rbac/access/*.yaml; do kubectl apply -f "$f"; done

step "3/8 Secrets (created only if missing)"
ensure_secret "$NS_POSTGRES" postgres-secret POSTGRES_PASSWORD
ensure_secret "$NS_MINIO" minio-secret MINIO_ROOT_USER MINIO_ROOT_PASSWORD
ensure_secret "$NS_BACKEND" server-secret DATABASE_URL DEFAULT_ADMIN_PASSWORD JWT_SECRET MINIO_ACCESS_KEY MINIO_SECRET_KEY

step "4/8 Postgres"
apply_as p-user k8s-db/postgres-configmap.yml k8s-db/postgres-service.yml k8s-db/db-statefulset.yml
wait_ready statefulset/postgres "$NS_POSTGRES"
retain_pv "$NS_POSTGRES" postgres-storage-postgres-0

step "5/8 MinIO"
apply_as m-user k8s-minio/minio-service.yml k8s-minio/minio-statefulset.yml
wait_ready statefulset/minio "$NS_MINIO"
retain_pv "$NS_MINIO" minio-storage-minio-0

step "6/8 Backend"
apply_as b-user k8s-server/server-configmap.yml k8s-server/server-service.yml k8s-server/server-deployment.yml
wait_ready deployment/server-deployment "$NS_BACKEND"

step "7/8 Frontend"
apply_as f-user k8s-client/client-server-alias.yml k8s-client/client-configmap.yml k8s-client/client-service.yml k8s-client/client-deployment.yml
wait_ready deployment/client-deployment "$NS_FRONTEND"

step "8/8 Ingresses"
apply_as f-user ingress/ingress-frontend.yml
apply_as b-user ingress/ingress-backend.yml
apply_as m-user ingress/ingress-minio.yml

step "Done"
for ns in "$NS_POSTGRES" "$NS_MINIO" "$NS_BACKEND" "$NS_FRONTEND"; do
  echo "--- $ns"; kubectl get pods,pvc,ingress -n "$ns"
done
