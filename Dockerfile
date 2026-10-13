# syntax=docker/dockerfile:1
#
# 运行镜像（不在镜像里编译）：只装常用工具，放入**预编译好的 Linux 单二进制**。
# 二进制由 CI 的 binaries job 交叉编译（纯 Go、无 QEMU），按目标架构放在
# 构建上下文的 dist/<TARGETARCH>/artex。这样多架构构建时 arm64 只需模拟 apt 层，
# 不再模拟 Next/Go 编译，速度快得多。
#
# 本地手动构建镜像时，先自行准备二进制：
#   cd web && npm run build:static && cd ..
#   cp -r web/out server/webui/dist
#   CGO_ENABLED=0 GOARCH=amd64 go build -tags embedui -o dist/amd64/artex ./cmd/artex
#   docker build -t artex:local .
FROM python:3.12-slim-bookworm
ARG TARGETARCH
# 常用工具：ripgrep / curl / vim，加一批 recon 常备件（按需增删）。
# Node 来源：nodejs 官方 tarball（自带 npm），**不再**走 NodeSource 的 apt 脚本。
# 原因（2026-10-13 实测）：setup_20.x 脚本内部先要 apt-get install gnupg，该步一旦被
# 镜像源 502 打断，脚本自己仍以 exit 0 收尾，&& 链继续往下走，apt 就静默回退到
# Debian bookworm 自带的 nodejs 18——而那个包**不含 npm**，下一层 `npm` 直接 exit 127，
# 报错还只显示 "npm: not found"，极难定位。官方 tarball 版本固定、自带 npm、
# 不依赖任何第三方 apt 源，把这个失败模式彻底消掉（bookworm 自带 nodejs 是 18，
# 而 Playwright 要求 >=20，故也不能直接用 apt 的 nodejs）。
# 注：曾用「落盘 + 比对 SHA256 再执行 setup_20.x」的 fail-closed 方案，但哈希只能
# 保证脚本没被篡改，挡不住它内部 apt-get 失败后仍 exit 0 这一类问题，故弃用。
# NODE_MIRROR 可覆盖为国内加速地址；主源失败会自动回退 registry.npmmirror.com。
ARG NODE_VERSION=20.20.0
ARG NODE_MIRROR=https://nodejs.org/dist
# 可选构建参数:APT 镜像站(默认官方 deb.debian.org;国内可传 mirrors.aliyun.com 或 mirrors.ustc.edu.cn)
ARG APT_MIRROR=
ARG NPM_REGISTRY=https://registry.npmjs.org
RUN if [ -n "$APT_MIRROR" ]; then \
      sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    fi \
    && apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 update \
    && apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 install -y --no-install-recommends \
      ca-certificates ripgrep curl wget vim git jq unzip \
      dnsutils iputils-ping netcat-openbsd inetutils-telnet whois nmap \
    && rm -rf /var/lib/apt/lists/*
# 装 Node + npm（官方二进制；装完显式打印版本，npm 缺失时立即 fail-closed）
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      amd64) narch=x64 ;; \
      arm64) narch=arm64 ;; \
      *) echo "unsupported arch: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    ok=0; \
    for base in "$NODE_MIRROR" "https://registry.npmmirror.com/-/binary/node"; do \
      url="$base/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${narch}.tar.gz"; \
      if curl -fsSL --retry 3 --retry-connrefused --connect-timeout 15 "$url" -o /tmp/node.tar.gz; then ok=1; break; fi; \
      echo "warn: 下载失败，尝试下一个镜像源: $url" >&2; \
    done; \
    [ "$ok" = 1 ] || { echo "error: 无法下载 node v${NODE_VERSION}" >&2; exit 1; }; \
    tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1; \
    rm -f /tmp/node.tar.gz; \
    node -v; npm -v
# 预装 Playwright MCP 与 CLI（全局），运行时不再 npx 联网下载。
# 版本钉死（2026-09-13 自 npm registry 的 latest 取值）：@latest 会让同一 Dockerfile
# 在不同时间构建出不同镜像，升级时应有意识地 bump 并记录，而不是被隐式漂移。
# @playwright/mcp：browser MCP 直接 `npx @playwright/mcp`（已全局装好，无需 -y/@latest）。
# @playwright/cli：提供 playwright-cli，装完顺带 --help 验证可执行。
# 再装 playwright（提供浏览器管理），装完用 --with-deps 预置 chromium 及其系统依赖，
# 这样容器内 MCP/CLI 首次启动即可用，不再联网下载浏览器。
RUN npm config set registry "$NPM_REGISTRY" \
    && npm install -g @playwright/mcp@0.0.80 @playwright/cli@0.1.19 playwright@1.63.0 \
    && playwright-cli --help \
    && playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# 预编译好的对应架构二进制（dist/amd64/artex 或 dist/arm64/artex）
COPY dist/${TARGETARCH}/artex /app/artex
# 守护启动脚本：进程退出后按退出码决定是否重新拉起，页面一键更新靠它完成换装。
# 它同时负责把 SIGTERM 转发给 artex —— docker stop 只把信号发给 PID 1，
# 不转发的话 artex 收不到、做不了优雅关闭，10 秒后被 SIGKILL 硬杀。
COPY start.sh /app/start.sh
RUN chmod +x /app/artex /app/start.sh
COPY skills/ /app/skills/
# data/（SQLite + jwt.key）持久化点
VOLUME ["/app/data"]
EXPOSE 8787 8788
ENTRYPOINT ["/app/start.sh"]
CMD ["-addr", ":8787", "-proxy", ":8788"]
