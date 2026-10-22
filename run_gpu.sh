set -u
TREE="$1"
say() { echo "[livefix] $*"; }
. /tmp/opencode/gpufns.sh
. /tmp/opencode/gpubody.sh
gpu_manifest_summary
