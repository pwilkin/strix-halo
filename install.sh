#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly installer_name=${0##*/}
readonly rocm_repo_url=https://github.com/pwilkin/rocm-systems.git
readonly rocm_repo_branch=ilintar-experiments
readonly rocm_repo_commit=7dda3ac6cfe6bbe0b7f08c23a67cfa118d8641a1
readonly llama_repo_url=https://github.com/pwilkin/llama.cpp.git
readonly llama_repo_branch=strix-halo
readonly llama_repo_commit=40c0b9c3835bf4e923570fb5929df5b59b50638f

# STRIX_PROFILE picks which model this installer builds for. Both profiles share the
# runtime and engine build; they differ in the weights and in the launcher flags.
readonly profile=${STRIX_PROFILE:-qwen38-27b}
case $profile in
  qwen38-27b)
    readonly model_repo=ilintar/qwen3.8-27b-gguf-strix-halo
    readonly model_files=(
      Qwen3.8-27B-IQ4_XS-ALL-IMATRIX-Q8-OUT-MTP.gguf:9e5f86c794b45b215a2768723c94819500c0c8f896094d628728e6fc94cd6324
      Qwen3.8-27B-DFlash2-IQ4_XS.gguf:11c7848014bd68040a42837b381bbefff5d0acc22cf20b6055a48d560c834445
    )
    readonly main_model_name=Qwen3.8-27B-IQ4_XS-ALL-IMATRIX-Q8-OUT-MTP.gguf
    readonly draft_model_name=Qwen3.8-27B-DFlash2-IQ4_XS.gguf
    readonly mmproj_repo=bartowski/Qwen3.8-27B-GGUF
    readonly mmproj_name=mmproj-Qwen3.8-27B-bf16.gguf
    readonly mmproj_sha256=e43a597863a21bfa48b0fbd4553a771ae4117e25bb172e66f1dbc3fc6d037131
    readonly model_disk_gib=30
    ;;
  flash-next)
    # 9 IQ4_NL shards plus the shared-embedding MTP draft. No projector: this one is text only.
    readonly model_repo=ilintar/qwen3.8-flash-next-gguf-strix-halo
    readonly model_files=(
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf:5b6032b1f3428a148a3b63d661a992dbe0e5f8e278ab684b3d2b474bc5372d30
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00002-of-00009.gguf:81ea612c230e5c3ee1e1036873b316bd6f3d0ba00aa9e12da9238b3ec75ef643
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00003-of-00009.gguf:d4c2432777ad3f2073989d9b584aaa69ea53201c22bfa69b0efc58fb3d4ffb9c
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00004-of-00009.gguf:72e276e9ffd33891b0640136b7f8c3ac765d34b3fae57d91cdbd4d25ce61477c
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00005-of-00009.gguf:c61c34d8c6e27051fb903f7117c6577cbd87b945e7fcdd3b7642a794dec78bac
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00006-of-00009.gguf:c9b36bca38ad5994c24a9d840460c7c3763cd64dfe2816effe1eabef5d7fc77a
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00007-of-00009.gguf:b18c40e93081df6b1001ed344af7de796f07a754f23001376cc9ed2d400effba
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00008-of-00009.gguf:3389e8907ce093d3ad45f5b46f14098d34352241cbc676361edbed7186ab023e
      Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00009-of-00009.gguf:8229be447e559c6f1186d8c878621afcf3466de71aca1b1c97e895288723b36e
      mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf:5ff54097406a905cf3a724c709124ceb0e3e10235ee862298969e91c96fa96e6
    )
    readonly main_model_name=Qwen3.8-Flash-Next-IQ4_NL-PROJFIX-00001-of-00009.gguf
    readonly draft_model_name=mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf
    readonly mmproj_repo=
    readonly mmproj_name=
    readonly mmproj_sha256=
    readonly model_disk_gib=110
    ;;
  *)
    printf 'unknown STRIX_PROFILE: %s (expected qwen38-27b or flash-next)\n' "$profile" >&2
    exit 2
    ;;
esac

install_root=${STRIX_HALO_INSTALL_ROOT:-$HOME/.local/share/qwen3.8-strix-halo}
model_dir=${STRIX_HALO_MODEL_DIR:-}
model_dir_explicit=0
if [[ -n $model_dir ]]; then
  model_dir_explicit=1
fi
jobs=${JOBS:-}
install_packages=1
check_only=0

usage() {
  cat <<EOF
Usage: $installer_name [options]

Build the tested Strix Halo ROCm runtime and llama.cpp, download the selected
Qwen3.8 target and DFlash2 models, and install launchers in ~/.local/bin.

Options:
  --install-root DIR   Installation root
                       default: ~/.local/share/qwen3.8-strix-halo
  --model-dir DIR      Model directory; skips the interactive prompt
  --jobs N             Parallel build jobs; default: min(nproc, 16)
  --skip-packages      Do not install distribution build packages
  --check-only         Verify the driver, build tools, and ROCm SDK, then exit
  -h, --help           Show this help

Environment equivalents:
  STRIX_HALO_INSTALL_ROOT, STRIX_HALO_MODEL_DIR, JOBS

During an interactive installation, the model directory is requested with
~/.models as the default. Unattended runs use ~/.models automatically unless
--model-dir or STRIX_HALO_MODEL_DIR is set.

Run this script as your normal desktop user. It uses sudo only when missing
distribution build packages must be installed. It never replaces system ROCm
libraries; the custom HIP and ROCr libraries remain inside INSTALL_ROOT.
EOF
}

log() {
  printf '\n[%s] %s\n' "$installer_name" "$*"
}

warn() {
  printf '\n[%s] WARNING: %s\n' "$installer_name" "$*" >&2
}

die() {
  printf '\n[%s] ERROR: %s\n' "$installer_name" "$*" >&2
  exit 1
}

on_error() {
  local status=$?
  printf '\n[%s] Failed at line %s: %s\n' "$installer_name" "$1" "$2" >&2
  exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

while (($#)); do
  case "$1" in
    --install-root)
      (($# >= 2)) || die '--install-root requires a directory'
      install_root=$2
      shift 2
      ;;
    --model-dir)
      (($# >= 2)) || die '--model-dir requires a directory'
      model_dir=$2
      model_dir_explicit=1
      shift 2
      ;;
    --jobs)
      (($# >= 2)) || die '--jobs requires a positive integer'
      jobs=$2
      shift 2
      ;;
    --skip-packages)
      install_packages=0
      shift
      ;;
    --check-only)
      check_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n ${HOME:-} && $HOME == /* ]] || die 'HOME must be an absolute path'
[[ $install_root == /* ]] || die '--install-root must be an absolute path'
if ((model_dir_explicit == 0)); then
  if ((check_only == 0)) && [[ -t 0 ]]; then
    printf 'Model directory [%s]: ' "$HOME/.models" >&2
    read -r model_dir || true
  fi
  model_dir=${model_dir:-$HOME/.models}
fi
case $model_dir in
  '~')
    model_dir=$HOME
    ;;
  '~/'*)
    model_dir=$HOME/${model_dir#\~/}
    ;;
esac
if [[ -z $model_dir ]]; then
  model_dir=$HOME/.models
fi
[[ $model_dir == /* ]] || die '--model-dir must be an absolute path'

if [[ -z $jobs ]]; then
  jobs=$(nproc)
  if ((jobs > 16)); then
    jobs=16
  fi
fi
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer'

if ((EUID == 0)) && [[ -n ${SUDO_USER:-} ]]; then
  die 'do not run the installer with sudo; run it as your normal desktop user'
fi

run_privileged() {
  if ((EUID == 0)); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "sudo is required to install packages: $*"
  fi
}

install_build_packages() {
  ((install_packages == 1)) || return 0

  if command -v apt-get >/dev/null 2>&1; then
    local packages=(
      build-essential ca-certificates cmake curl git libcurl4-openssl-dev
      libdrm-dev libdw-dev libelf-dev libgl-dev libnuma-dev libpciaccess-dev
      libssl-dev libudev-dev libzstd-dev ninja-build pciutils pkg-config
      python3 python3-pip python3-venv xxd zlib1g-dev
    )
    local missing=()
    local package
    for package in "${packages[@]}"; do
      if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed'; then
        missing+=("$package")
      fi
    done
    if ((${#missing[@]})); then
      log "Installing missing Debian/Ubuntu packages: ${missing[*]}"
      run_privileged apt-get update
      run_privileged apt-get install -y --no-install-recommends "${missing[@]}"
    fi
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    local packages=(
      ca-certificates cmake curl elfutils-libelf-devel gcc gcc-c++ git
      libcurl-devel libdrm-devel libglvnd-devel libstdc++-devel libzstd-devel
      make ninja-build numactl-devel openssl-devel pciutils pkgconf-pkg-config
      python3 python3-pip python3-devel vim-common zlib-devel
    )
    local missing=()
    local package
    for package in "${packages[@]}"; do
      rpm -q "$package" >/dev/null 2>&1 || missing+=("$package")
    done
    if ((${#missing[@]})); then
      log "Installing missing Fedora/RHEL packages: ${missing[*]}"
      run_privileged dnf install -y "${missing[@]}"
    fi
    return 0
  fi

  if command -v pacman >/dev/null 2>&1; then
    local packages=(
      base-devel ca-certificates cmake curl git libdrm libelf libglvnd
      libxcrypt ninja numactl openssl pciutils pkgconf python python-pip vim
      zlib zstd
    )
    local missing=()
    local package
    for package in "${packages[@]}"; do
      pacman -Q "$package" >/dev/null 2>&1 || missing+=("$package")
    done
    if ((${#missing[@]})); then
      log "Installing missing Arch packages: ${missing[*]}"
      run_privileged pacman -S --needed --noconfirm "${missing[@]}"
    fi
    return 0
  fi

  warn 'No supported package manager found; checking existing tools only.'
}

require_commands() {
  local missing=()
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done
  ((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}"
}

verify_driver() {
  log 'Verifying the AMD kernel driver and Strix Halo GPU'
  [[ $(uname -s) == Linux ]] || die 'this installer supports Linux only'
  [[ $(uname -m) == x86_64 ]] || die 'this installer currently supports x86_64 only'
  [[ -d /sys/module/amdgpu ]] || die 'the amdgpu kernel module is not loaded'
  [[ -c /dev/kfd ]] || die '/dev/kfd is missing; install or enable an AMDGPU/ROCm-capable kernel driver'
  [[ -r /dev/kfd && -w /dev/kfd ]] || die 'the current user cannot access /dev/kfd; add the user to the render and video groups, then log in again'

  local render_nodes=()
  shopt -s nullglob
  render_nodes=(/dev/dri/renderD*)
  shopt -u nullglob
  ((${#render_nodes[@]})) || die 'no DRM render node was found under /dev/dri'

  local render_ok=0
  local node
  for node in "${render_nodes[@]}"; do
    if [[ -r $node && -w $node ]]; then
      render_ok=1
      break
    fi
  done
  ((render_ok == 1)) || die 'the current user cannot access any DRM render node; add the user to the render and video groups, then log in again'

  local gfx_versions
  gfx_versions=$(awk '$1 == "gfx_target_version" && $2 != 0 { print $2 }' /sys/class/kfd/kfd/topology/nodes/*/properties 2>/dev/null | sort -u || true)
  grep -qx '110501' <<<"$gfx_versions" || die "gfx1151 was not detected in KFD topology; detected target versions: ${gfx_versions:-none}"
  log 'Detected an accessible gfx1151 device through amdgpu/KFD.'
}

detect_rocm_root() {
  local candidate=${ROCM_ROOT:-}
  if [[ -z $candidate ]] && command -v hipconfig >/dev/null 2>&1; then
    candidate=$(hipconfig --rocmpath 2>/dev/null | tail -n 1)
  fi
  if [[ -z $candidate && -x /opt/rocm/bin/hipconfig ]]; then
    candidate=$(/opt/rocm/bin/hipconfig --rocmpath 2>/dev/null | tail -n 1)
  fi
  if [[ -z $candidate ]]; then
    die 'a complete ROCm SDK was not found; install ROCm with HIP, hipBLAS, rocBLAS, LLVM development files, and rocprofiler-register first'
  fi
  realpath "$candidate"
}

verify_rocm_sdk() {
  local root=$1
  log "Verifying the system ROCm SDK at $root"
  [[ -x $root/bin/hipcc ]] || die "missing $root/bin/hipcc"
  [[ -x $root/lib/llvm/bin/clang++ ]] || die "missing ROCm clang++ under $root/lib/llvm/bin"
  [[ -x $root/lib/llvm/bin/llvm-mc ]] || die "missing ROCm llvm-mc under $root/lib/llvm/bin"

  local package
  for package in hip hipblas rocblas amd_comgr rocprofiler-register; do
    [[ -d $root/lib/cmake/$package || -d $root/lib64/cmake/$package ]] || die "missing ROCm CMake package: $package"
  done

  local version
  version=$($root/bin/hipconfig --version 2>/dev/null | head -n 1)
  local version_core=${version%%-*}
  local major=${version_core%%.*}
  local remainder=${version_core#*.}
  local minor=${remainder%%.*}
  [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || die "could not parse HIP version: $version"
  ((major > 6 || (major == 6 && minor >= 1))) || die "HIP 6.1 or newer is required; found $version"
  log "Found HIP $version."
}

require_free_space() {
  local path=$1
  local required_gib=$2
  local available_kib
  available_kib=$(df -Pk "$path" | awk 'NR == 2 { print $4 }')
  local required_kib=$((required_gib * 1024 * 1024))
  ((available_kib >= required_kib)) || die "$path needs at least ${required_gib} GiB free; only $((available_kib / 1024 / 1024)) GiB is available"
}

checkout_pinned() {
  local label=$1
  local url=$2
  local branch=$3
  local commit=$4
  local destination=$5

  if [[ ! -e $destination ]]; then
    log "Cloning $label branch $branch"
    git clone --filter=blob:none --single-branch --branch "$branch" "$url" "$destination"
  elif [[ ! -d $destination/.git ]]; then
    die "$destination exists but is not a Git checkout"
  fi

  local configured_url
  local expected_ssh=git@github.com:${url#https://github.com/}
  configured_url=$(git -C "$destination" remote get-url origin)
  [[ $configured_url == "$url" || $configured_url == "$expected_ssh" ]] || die "$destination uses unexpected origin $configured_url"

  if [[ $label == 'pwilkin/rocm-systems' ]]; then
    local generated_profile_header=projects/clr/hipamd/include/hip/amd_detail/hip_prof_str.h
    if ! git -C "$destination" diff --quiet -- "$generated_profile_header"; then
      warn "Restoring $generated_profile_header after the HIP build regenerated it"
      git -C "$destination" restore --worktree -- "$generated_profile_header"
    fi
  fi
  [[ -z $(git -C "$destination" status --porcelain) ]] || die "$destination has local changes; preserve or remove them before rerunning the installer"

  git -C "$destination" fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"
  if ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$destination" fetch origin "$commit"
  fi
  git -C "$destination" merge-base --is-ancestor "$commit" "origin/$branch" || die "$commit is no longer contained in origin/$branch"
  git -C "$destination" -c advice.detachedHead=false checkout --detach "$commit"
  [[ $(git -C "$destination" rev-parse HEAD) == "$commit" ]] || die "failed to pin $label to $commit"
  log "$label pinned to $commit."
}

join_existing_paths() {
  local result=
  local path
  for path in "$@"; do
    [[ -d $path ]] || continue
    if [[ -n $result ]]; then
      result+=:
    fi
    result+=$path
  done
  printf '%s\n' "$result"
}

verify_sha256() {
  local path=$1
  local expected=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum --check --status
}

download_hf_file() {
  local hf=$1
  local repo=$2
  local filename=$3
  local expected=$4
  local destination=$model_dir/$filename

  if [[ -f $destination ]]; then
    log "Verifying existing $filename"
    verify_sha256 "$destination" "$expected" || die "$destination exists but its SHA-256 does not match"
    return 0
  fi

  log "Downloading $repo/$filename"
  HF_HOME="$hf_home" \
  HF_XET_LOG_DIR="$hf_home/xet/logs" \
  HF_XET_HIGH_PERFORMANCE=1 \
    "$hf" download "$repo" "$filename" --local-dir "$model_dir"
  verify_sha256 "$destination" "$expected" || die "SHA-256 verification failed for $destination"
}

add_path_block() {
  local file=$1
  local marker='# qwen3.8-strix-halo local launchers'
  if [[ -f $file ]] && grep -Fq "$marker" "$file"; then
    return 0
  fi
  {
    printf '\n%s\n' "$marker"
    printf 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n'
  } >>"$file"
}

write_launchers() {
  local config=$install_root/config.sh
  local generic=$local_bin/llama-server-strix-halo
  local optimized=$local_bin/qwen3.8-strix-halo-server
  local config_tmp
  local generic_tmp
  local optimized_tmp
  config_tmp=$(mktemp "$install_root/config.sh.tmp.XXXXXX")
  generic_tmp=$(mktemp "$install_root/llama-server-strix-halo.tmp.XXXXXX")
  optimized_tmp=$(mktemp "$install_root/qwen3.8-strix-halo-server.tmp.XXXXXX")

  {
    printf 'STRIX_LLAMA_SERVER=%q\n' "$llama_server"
    printf 'STRIX_RUNTIME_LIBS=%q\n' "$runtime_libs"
    printf 'STRIX_ROCM_ROOT=%q\n' "$rocm_root"
    printf 'STRIX_MAIN_MODEL=%q\n' "$model_dir/$main_model_name"
    printf 'STRIX_DFLASH_MODEL=%q\n' "$model_dir/$draft_model_name"
    if [[ -n $mmproj_name ]]; then
      printf 'STRIX_MMPROJ_MODEL=%q\n' "$model_dir/$mmproj_name"
    fi
    printf 'STRIX_GENERIC_WRAPPER=%q\n' "$generic"
  } >"$config_tmp"
  chmod 0644 "$config_tmp"
  mv "$config_tmp" "$config"

  cat >"$generic_tmp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source $(printf '%q' "$config")
export PATH="\$STRIX_ROCM_ROOT/bin:\$PATH"
export LD_LIBRARY_PATH="\$STRIX_RUNTIME_LIBS\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export HSA_OVERRIDE_GFX_VERSION="\${HSA_OVERRIDE_GFX_VERSION:-11.5.1}"
export GGML_HIP_ENABLE_UNIFIED_MEMORY="\${GGML_HIP_ENABLE_UNIFIED_MEMORY:-1}"
unset DEBUG_HIP_GRAPH_PM4_UNQUALIFIED
enable_retained_pm4="\${ENABLE_RETAINED_PM4:-1}"
export ENABLE_RETAINED_PM4="\$enable_retained_pm4"
if [[ \$enable_retained_pm4 == 1 ]]; then
  unset GGML_CUDA_DISABLE_GRAPHS
  export DEBUG_HIP_GRAPH_PM4=1
else
  export GGML_CUDA_DISABLE_GRAPHS=1
  unset DEBUG_HIP_GRAPH_PM4
fi
exec "\$STRIX_LLAMA_SERVER" "\$@"
EOF
  install -m 0755 "$generic_tmp" "$generic"

  if [[ $profile == flash-next ]]; then
    cat >"$optimized_tmp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source $(printf '%q' "$config")
# --load-mode none with --lazy-mode on-direct is what keeps the 27.5 GB per-layer-embedding
# table out of the resident set: the rows are pread() on demand instead of being faulted in
# through an mmap that would also hold a second copy of every weight during load.
ctx_size="\${CTX_SIZE:-65536}"
batch_size="\${BATCH_SIZE:-16384}"
ubatch_size="\${UBATCH_SIZE:-16384}"
parallel="\${PARALLEL:-1}"
draft_n_max="\${MTP_N_MAX:-2}"
export LLAMA_MMB=\${LLAMA_MMB:-1} LLAMA_MMB_MIN_T=\${LLAMA_MMB_MIN_T:-512} \\
  LLAMA_MMB_BF16W=\${LLAMA_MMB_BF16W:-1} LLAMA_MMB_GLU=\${LLAMA_MMB_GLU:-1} \\
  LLAMA_MMB_TALL=\${LLAMA_MMB_TALL:-2} LLAMA_MMB_CACHE=\${LLAMA_MMB_CACHE:-4} \\
  LLAMA_MMB_F32SPLIT=\${LLAMA_MMB_F32SPLIT:-2} LLAMA_MMB_HC16=\${LLAMA_MMB_HC16:-2} \\
  LLAMA_MMB_SHADOW=\${LLAMA_MMB_SHADOW:-2} LLAMA_MMB_DOWN16=\${LLAMA_MMB_DOWN16:-1} \\
  LLAMA_HC_CN_SHAPE=\${LLAMA_HC_CN_SHAPE:-1} LLAMA_HC_GATEMIX=\${LLAMA_HC_GATEMIX:-1} \\
  LLAMA_HC_MIX_FUSE=\${LLAMA_HC_MIX_FUSE:-1} LLAMA_HC_BLK16=\${LLAMA_HC_BLK16:-1} \\
  LLAMA_HC_RES16=\${LLAMA_HC_RES16:-1} LLAMA_HC_PACK_DI=\${LLAMA_HC_PACK_DI:-1} \\
  LLAMA_NORM_GATED=\${LLAMA_NORM_GATED:-1} LLAMA_NORM_ROWS=\${LLAMA_NORM_ROWS:-1} \\
  LLAMA_IDX_RELU_SUM=\${LLAMA_IDX_RELU_SUM:-1} LLAMA_PLE_CONV=\${LLAMA_PLE_CONV:-1} \\
  LLAMA_GDN_CONV=\${LLAMA_GDN_CONV:-1} \\
  LLAMA_QSA_SPARSE=\${LLAMA_QSA_SPARSE:-1} LLAMA_QSA_WHOLE_ATTN=\${LLAMA_QSA_WHOLE_ATTN:-1} \\
  LLAMA_QSA_BLOCK_SELECTION=\${LLAMA_QSA_BLOCK_SELECTION:-1} \\
  LLAMA_QSA_COMPACT_METADATA=\${LLAMA_QSA_COMPACT_METADATA:-1} \\
  LLAMA_QSA_DENSE_SHORTCUT=\${LLAMA_QSA_DENSE_SHORTCUT:-1} \\
  LLAMA_QSA_DIRECT_INDICES=\${LLAMA_QSA_DIRECT_INDICES:-1} \\
  LLAMA_QSA_PACK_KEYS=\${LLAMA_QSA_PACK_KEYS:-1} LLAMA_QSA_PACK_VALUES=\${LLAMA_QSA_PACK_VALUES:-1} \\
  LLAMA_QSA_QUERY_STRIP=\${LLAMA_QSA_QUERY_STRIP:-512} \\
  LLAMA_QSA_SCORE_BOUNDS=\${LLAMA_QSA_SCORE_BOUNDS:-1} \\
  LLAMA_QSA_NO_DENSE_MASK=\${LLAMA_QSA_NO_DENSE_MASK:-1} \\
  LLAMA_QSA_FA_V3=\${LLAMA_QSA_FA_V3:-1} LLAMA_QSA_FUSE_EXPAND=\${LLAMA_QSA_FUSE_EXPAND:-1} \\
  LLAMA_MTP_QSA=\${LLAMA_MTP_QSA:-1} LLAMA_MTP_QSA_MIN_T=\${LLAMA_MTP_QSA_MIN_T:-128}
exec "\$STRIX_GENERIC_WRAPPER" \\
  -m "\$STRIX_MAIN_MODEL" \\
  -dev ROCm0 \\
  -ngl 999 \\
  -fa on \\
  -fit off \\
  --load-mode none \\
  --lazy-mode on-direct \\
  -ctk f16 -ctv f16 \\
  -c "\$ctx_size" \\
  -b "\$batch_size" \\
  -ub "\$ubatch_size" \\
  --parallel "\$parallel" \\
  --jinja \\
  --spec-type draft-mtp \\
  --spec-draft-model "\$STRIX_DFLASH_MODEL" \\
  --spec-draft-device ROCm0 \\
  --spec-draft-ngl 99 \\
  --spec-draft-n-max "\$draft_n_max" \\
  "\$@"
EOF
    install -m 0755 "$optimized_tmp" "$optimized"
    return
  fi

  cat >"$optimized_tmp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source $(printf '%q' "$config")
ctx_size="\${CTX_SIZE:-65536}"
batch_size="\${BATCH_SIZE:-2048}"
ubatch_size="\${UBATCH_SIZE:-512}"
parallel="\${PARALLEL:-1}"
draft_n_min="\${DFLASH_N_MIN:-0}"
draft_n_max="\${DFLASH_N_MAX:-6}"
draft_p_min="\${DFLASH_P_MIN:-0.10}"
exec "\$STRIX_GENERIC_WRAPPER" \\
  -m "\$STRIX_MAIN_MODEL" \\
  --mmproj "\$STRIX_MMPROJ_MODEL" \\
  --mmproj-device ROCm0 \\
  -dev ROCm0 \\
  -ngl 999 \\
  -fa on \\
  -fit off \\
  --load-mode none \\
  -c "\$ctx_size" \\
  -b "\$batch_size" \\
  -ub "\$ubatch_size" \\
  --parallel "\$parallel" \\
  --jinja \\
  --spec-type draft-dflash \\
  --spec-draft-model "\$STRIX_DFLASH_MODEL" \\
  --spec-draft-device ROCm0 \\
  --spec-draft-ngl 99 \\
  --spec-draft-n-min "\$draft_n_min" \\
  --spec-draft-n-max "\$draft_n_max" \\
  --spec-draft-p-min "\$draft_p_min" \\
  "\$@"
EOF
  install -m 0755 "$optimized_tmp" "$optimized"
  rm -f "$generic_tmp" "$optimized_tmp"

  add_path_block "$HOME/.profile"
  if [[ -f $HOME/.bashrc ]]; then
    add_path_block "$HOME/.bashrc"
  fi
  if [[ ${SHELL:-} == */zsh ]]; then
    add_path_block "$HOME/.zshrc"
  fi
}

log 'Preparing system build dependencies'
install_build_packages
require_commands awk cmake curl df git grep ldd make mktemp nproc pkg-config python3 realpath sha256sum sort
for pc_module in libdrm libdrm_amdgpu libelf; do
  pkg-config --exists "$pc_module" || die "pkg-config module $pc_module is missing"
done

verify_driver
rocm_root=$(detect_rocm_root)
verify_rocm_sdk "$rocm_root"
if ((check_only == 1)); then
  log 'All prerequisite checks passed.'
  exit 0
fi

mkdir -p "$install_root" "$model_dir"
if [[ $(stat -c %d "$install_root") == $(stat -c %d "$model_dir") ]]; then
  require_free_space "$install_root" 30
else
  require_free_space "$install_root" 8
  require_free_space "$model_dir" 20
fi

local_bin=$HOME/.local/bin
source_root=$install_root/src
build_root=$install_root/build
runtime_root=$install_root/runtime
cache_root=$install_root/cache
hf_home=$cache_root/huggingface
venv=$install_root/venv
rocm_source=$source_root/rocm-systems
llama_source=$source_root/llama.cpp
rocr_build=$build_root/rocr
hip_build=$build_root/hip
llama_build=$build_root/llama.cpp
rocr_install=$runtime_root/rocr
hip_install=$runtime_root/hip

mkdir -p "$local_bin" "$source_root" "$build_root" "$runtime_root" "$hf_home/xet/logs"
export PATH="$local_bin:$PATH"

log 'Preparing the Python environment used by the HIP build and model downloader'
if [[ ! -x $venv/bin/python ]]; then
  python3 -m venv "$venv"
fi
PIP_DISABLE_PIP_VERSION_CHECK=1 "$venv/bin/python" -m pip install --upgrade pip
PIP_DISABLE_PIP_VERSION_CHECK=1 "$venv/bin/python" -m pip install 'CppHeaderParser==2.7.4' 'huggingface_hub[hf_xet]>=0.36.0'

checkout_pinned 'pwilkin/rocm-systems' "$rocm_repo_url" "$rocm_repo_branch" "$rocm_repo_commit" "$rocm_source"
checkout_pinned 'pwilkin/llama.cpp' "$llama_repo_url" "$llama_repo_branch" "$llama_repo_commit" "$llama_source"

system_rocm_libs=$(join_existing_paths "$rocm_root/lib" "$rocm_root/lib64" "$rocm_root/lib/llvm/lib")

log 'Configuring and building the custom ROCr runtime'
PATH="$venv/bin:$rocm_root/bin:$PATH" cmake \
  -S "$rocm_source/projects/rocr-runtime" \
  -B "$rocr_build" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$rocr_install" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="$rocm_root" \
  -DBUILD_SHARED_LIBS=ON
PATH="$venv/bin:$rocm_root/bin:$PATH" cmake --build "$rocr_build" --parallel "$jobs"
PATH="$venv/bin:$rocm_root/bin:$PATH" cmake --install "$rocr_build"
[[ -e $rocr_install/lib/libhsa-runtime64.so.1 ]] || die 'custom ROCr library was not installed'

hip_build_libs=$(join_existing_paths "$rocr_install/lib" "$rocm_root/lib" "$rocm_root/lib64" "$rocm_root/lib/llvm/lib")
log 'Configuring and building the custom HIP runtime'
PATH="$venv/bin:$rocm_root/bin:$PATH" \
LD_LIBRARY_PATH="$hip_build_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  cmake \
    -S "$rocm_source/projects/clr" \
    -B "$hip_build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$hip_install" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$rocr_install;$rocm_root" \
    -DCLR_BUILD_HIP=ON \
    -DCLR_BUILD_OCL=OFF \
    -DHIP_PLATFORM=amd \
    -DHIP_COMMON_DIR="$rocm_source/projects/hip" \
    -DHIPCC_BIN_DIR="$rocm_root/bin" \
    -DLLVM_ROOT="$rocm_root/lib/llvm" \
    -DClang_ROOT="$rocm_root/lib/llvm" \
    -DROCM_PATH="$rocr_install" \
    -Dhsa-runtime64_DIR="$rocr_install/lib/cmake/hsa-runtime64" \
    -DROCCLR_ENABLE_HSA=ON \
    -DROCCLR_ENABLE_PAL=OFF \
    -DHIP_ENABLE_ROCPROFILER_REGISTER=ON \
    -DUSE_PROF_API=ON \
    -D__HIP_ENABLE_PCH=ON
PATH="$venv/bin:$rocm_root/bin:$PATH" \
LD_LIBRARY_PATH="$hip_build_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  cmake --build "$hip_build" --parallel "$jobs"
PATH="$venv/bin:$rocm_root/bin:$PATH" \
LD_LIBRARY_PATH="$hip_build_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  cmake --install "$hip_build"
[[ -e $hip_install/lib/libamdhip64.so.7 ]] || die 'custom HIP library was not installed'

log 'Configuring and building llama.cpp for gfx1151'
PATH="$rocm_root/bin:$PATH" \
ROCM_PATH="$rocm_root" \
  cmake \
    -S "$llama_source" \
    -B "$llama_build" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$rocm_root" \
    -DGGML_HIP=ON \
    -DGPU_TARGETS=gfx1151 \
    -DGGML_HIP_GRAPHS=ON \
    -DGGML_HIP_NO_VMM=ON \
    -DGGML_HIP_MMQ_MFMA=ON \
    -DGGML_HIP_RCCL=OFF \
    -DGGML_CUDA_FA=ON \
    -DGGML_CUDA_FA_ALL_QUANTS=OFF \
    -DGGML_VULKAN=OFF \
    -DLLAMA_BUILD_TESTS=ON
PATH="$rocm_root/bin:$PATH" ROCM_PATH="$rocm_root" \
  cmake --build "$llama_build" --parallel "$jobs" --target llama-server llama-bench test-backend-sched-ring
"$llama_build/bin/test-backend-sched-ring"

llama_server=$llama_build/bin/llama-server
[[ -x $llama_server ]] || die 'llama-server was not built'
runtime_libs=$(join_existing_paths "$hip_install/lib" "$rocr_install/lib" "$rocm_root/lib" "$rocm_root/lib64" "$rocm_root/lib/llvm/lib" "$llama_build/bin")
ldd_output=$(LD_LIBRARY_PATH="$runtime_libs" ldd "$llama_build/bin/libggml-hip.so.0")
grep -Fq "$hip_install/lib/libamdhip64.so" <<<"$ldd_output" || die 'llama.cpp does not resolve libamdhip64 through the custom HIP prefix'
grep -Fq "$rocr_install/lib/libhsa-runtime64.so" <<<"$ldd_output" || die 'llama.cpp does not resolve libhsa-runtime64 through the custom ROCr prefix'

for entry in "${model_files[@]}"; do
  download_hf_file "$venv/bin/hf" "$model_repo" "${entry%%:*}" "${entry##*:}"
done

if [[ -n $mmproj_repo ]]; then
  log "Using the pinned projector $mmproj_repo/$mmproj_name"
  download_hf_file "$venv/bin/hf" "$mmproj_repo" "$mmproj_name" "$mmproj_sha256"
fi

log 'Installing launchers and updating the user PATH'
write_launchers

log 'Installation complete'
cat <<EOF

Installed under:
  $install_root

Models:
  $model_dir/$main_model_name
  $model_dir/$draft_model_name
  $model_dir/$mmproj_name

Launchers:
  $local_bin/qwen3.8-strix-halo-server
  $local_bin/llama-server-strix-halo

Open a new terminal, or run:
  source "$HOME/.profile"

Start the optimized Qwen3.8 server on localhost:
  qwen3.8-strix-halo-server

Listen on the LAN:
  qwen3.8-strix-halo-server --host 0.0.0.0 --port 8080

Use the custom runtime with an arbitrary llama-server command:
  llama-server-strix-halo -m /path/to/model.gguf [other llama-server options]

Useful runtime overrides:
  CTX_SIZE=32768 DFLASH_N_MAX=3 qwen3.8-strix-halo-server
  ENABLE_RETAINED_PM4=0 qwen3.8-strix-halo-server

The optimized launcher defaults to a 65536-token context and DFlash2 width 6.
Pass additional llama-server arguments normally; they are appended last.
EOF
