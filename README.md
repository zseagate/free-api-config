# Numes API 环境配置

Numes 是一个 OpenAI 兼容的 AI 推理市场 API，本仓库集中管理其环境配置、OpenCode 接入和连通性检测脚本。

> ⚠️ **安全**：真实 API Key 存放在被 `.gitignore` 忽略的 `.env` 中，**绝不提交**。仓库只包含 `.env.example` 占位符。

## 仓库结构

```
numes-api-config/
├── .env.example          # 环境变量模板(占位符, 可提交)
├── .env                  # 真实配置(已 gitignore, 不提交)
├── .gitignore
├── api-check.sh          # 连通性/可用性检测脚本
├── numes-opencode.jsonc  # OpenCode provider 配置示例(占位符)
└── README.md
```

## 快速开始

```bash
cp .env.example .env      # 然后编辑 .env 填入真实 NUMES_API_KEY
source .env               # 加载环境变量
echo $NUMES_API_KEY       # 验证
```

### 检测连通性

```bash
./api-check.sh                    # 检测全部 9 个免费模型(串行)
./api-check.sh --parallel         # 并行, 更快
./api-check.sh --watch 60 --parallel --stop-on-ok   # 每 60s 轮询, 恢复后自动退出
./api-check.sh --model z-ai/glm-5.3:free            # 指定模型
./api-check.sh --list-free                          # 列出已知免费模型
./api-check.sh --help                               # 全部参数
```

结果标记：`OK` 可用 / `TIMEOUT|HANG` 免费档繁忙 / `OVERLOAD` 429 限流 / `NOCREDIT` 余额不足 / `BADKEY` Key 无效。

## Numes 关键信息

| 项 | 值 |
|---|---|
| Base URL | `https://api.numes.ai/api/v1` |
| 鉴权 | `Authorization: Bearer $NUMES_API_KEY` |
| 模型 ID | `author/model` 全称, 如 `z-ai/glm-5.3-flash:free` |
| 免费模型数 | 9 个 (`:free` 后缀) |
| 付费模型数 | 300+ 个 |

免费模型 ID 列表（`api-check.sh --list-free`）：

```
z-ai/glm-5.3-flash:free
z-ai/glm-5.3:free
deepseek/deepseek-v4.1-flash:free
moonshotai/kimi-k3.1-pro:free
nvidia/nemotron-3-ultra-550b-a55b:free
dealignai/glm-5.3-flash-uncensored-fp8:free
dealignai/glm-5.3-uncensored-fp8:free
dealignai/deepseek-v4.1-flash-uncensored-fp8:free
uniboshi/kimi-k3-abliterated-v1:free
```

## 接入 OpenCode

参考 `numes-opencode.jsonc`，把其中的 `numes` 段合并进 `~/.config/opencode/opencode.jsonc`。
Key 通过环境变量引用 `{env:NUMES_API_KEY}`，无需在配置里写明文。

## 其他 OpenAI 兼容服务

本检测脚本也适用于任意 OpenAI 兼容 API：

```bash
./api-check.sh --base-url https://api.deepseek.com/v1 --key sk-xxx --model deepseek/deepseek-chat
```

## 许可证 / 维护

- 仅供个人使用。
- 变更 `.env` 前请确认已 gitignore。
