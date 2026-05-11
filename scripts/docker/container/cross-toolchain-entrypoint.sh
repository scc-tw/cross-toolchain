#!/usr/bin/env bash
# Entrypoint for finalfantasyliu/cross-toolchain image
#
# 動態 UID/GID matching (dockcross-style):
#   docker run -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) -v $PWD:/work \
#       finalfantasyliu/cross-toolchain ...
#
# → bind mount 檔案以 host user 身份 owned，不會出現 root-owned 檔卡死你
#
# 沒設 HOST_UID/HOST_GID 就用 build-time 預設 (uid=1000 gid=100)，OrbStack
# 的 virtiofs 會自動 remap 給 host user，不影響日常使用。

set -eu

# 動態 UID match
if [[ -n "${HOST_UID:-}" ]]; then
    cur_uid=$(id -u dev)
    if [[ "${cur_uid}" != "${HOST_UID}" ]]; then
        usermod -o -u "${HOST_UID}" dev
    fi
fi
if [[ -n "${HOST_GID:-}" ]]; then
    cur_gid=$(id -g dev)
    if [[ "${cur_gid}" != "${HOST_GID}" ]]; then
        # dev 主 group 名稱不一定 = "dev" (我們設的是 'users' gid 100)
        # 動態抓 dev 的 primary group name 來 groupmod
        cur_group=$(id -gn dev)
        groupmod -o -g "${HOST_GID}" "${cur_group}"
    fi
fi

# 沒參數 → interactive shell
# 有參數 → 用 dev 身份執行 (gosu = 輕量 sudo，不要 PTY)
if [[ $# -eq 0 ]]; then
    exec gosu dev /bin/bash
else
    exec gosu dev "$@"
fi
