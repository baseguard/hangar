ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"

fail() {
    echo "$*" >&2
    exit 1
}
