#!/bin/bash

set -e
exec > "$(dirname "$0")/cron.log" 2>&1

usage() {
    echo "Usage: $0 [Options] [Arguments...]"
    echo ""
    echo "Options:"
    echo "  -h,  --help     Show this help message"
    echo "  -t,  --tag      Specify tag upload"
    exit 0
}

tag=""

while getopts "ht:" opt; do
    case $opt in
        h)
            usage
            exit 0
            ;;
	      t)
            tag=$OPTARG
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done


build_and_upload() {
  local TAG="$1"
  local CLONE_SUCCESS=0
  rm -rf onnxruntime

  for i in $(seq 1 "$MAX_RETRIES"); do
    echo " 第 $i 次尝试 clone..."

    git clone --branch "$TAG" \
              --depth 1 "$REPO_URL" \
              onnxruntime && CLONE_SUCCESS=1 && break

    echo "第 $i 次 clone 失败，等待 $WAIT_SECONDS 秒后重试..."
    sleep "$WAIT_SECONDS"
  done

  if [ "$CLONE_SUCCESS" -ne 1 ]; then
    echo "连续 $MAX_RETRIES 次 git clone 失败，退出。"
    exit 1
  fi

  echo "git clone Success!!!"
  cd onnxruntime

  ./build.sh --allow_running_as_root \
             --config Release \
             --build_shared_lib \
             --parallel \
             --use_cann \
             --build_wheel \
             --skip_tests

  echo "开始上传到 PyPI (onnxruntime-cann)..."

  for ((i=1; i<=6; i++)); do
    echo "Attempt $i to upload package..."
    if python3 -m twine upload --repository onnxruntime-cann build/Linux/Release/dist/*.whl; then
      break
    else
      sleep "$WAIT_SECONDS"
    fi
  done

  if [ $i -gt $MAX_RETRIES ]; then
      echo " Maximum retry limit ($MAX_RETRIES) reached. Upload failed."
      exit 1
  fi
}

# 定时任务启动前要手动执行export -p > /root/.cron_env.sh 保证cron任务环境与终端一致。
source /root/.cron_env.sh
source /usr/local/Ascend/ascend-toolkit/set_env.sh
# 设置 HOME，避免找不到 ~/.pypirc 等
export HOME=/root

echo "================ Cron job started at $(date) ================"

# 切换到脚本所在目录执行
cd "$(dirname "$0")"
REPO="microsoft/onnxruntime"
API="https://api.github.com/repos/$REPO/tags"
REPO_URL="https://github.com/$REPO.git"
STATE_FILE="$(dirname "$0")/last_tag.txt"
MAX_RETRIES=10
WAIT_SECONDS=60

if [ -n "$tag" ]; then
  build_and_upload "$tag"
else
  # 获取最新 tag
  LATEST_TAG=$(curl -s --connect-timeout 15 --max-time 30 "$API" | grep '"name":' | head -n 1 | cut -d '"' -f 4)
  # 获取之前已上传记录的 tag
  if [ -f "$STATE_FILE" ]; then
    LAST_TAG=$(cat "$STATE_FILE")
  else
    LAST_TAG=""
  fi

  if [ "$LATEST_TAG" != "$LAST_TAG" ]; then
    echo "Detected new tag: $LATEST_TAG"
    build_and_upload "$LATEST_TAG"
    echo "$LATEST_TAG" > "$STATE_FILE"
  else
    echo "No new tag. Latest is still: $LATEST_TAG"
  fi
fi
echo "Done: ${tag:-$LATEST_TAG} uploaded"