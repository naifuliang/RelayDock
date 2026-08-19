# Configure Sub2API for RelayDock with Codex Desktop

This guide provides a reusable prompt for asking **Codex Desktop** to configure
a self-hosted Sub2API instance for RelayDock. The workflow is intended for a
Sub2API administrator who is already signed in to the administration page in a
local browser.

> [!IMPORTANT]
> This workflow requires Codex Desktop with Computer Use. Running `codex` in a
> terminal starts Codex CLI and does not, by itself, guarantee access to the
> signed-in browser or desktop Computer Use tools.

## Before you start

1. Install and sign in to Codex Desktop.
2. Open the Sub2API administrator page in your local browser and sign in.
3. Keep RelayDock open so you can import and verify the resulting endpoint.
4. Do not paste an API key into the prompt. Let the administrator page create
   the key, then store it directly in RelayDock's Keychain-backed field.

## Prompt for Codex Desktop

Copy the prompt below into a new Codex Desktop task. Codex should inspect the
current administrator state before making changes and request approval before
any destructive action.

```text
Use Computer Use to configure the Sub2API administrator page that is already
open and signed in on this Mac for use with RelayDock and Cursor.

Goal:
- Preserve every existing group, account binding, route, and API key.
- Create or reuse a dedicated Composite group named "relaydock".
- Bind the existing OpenAI and Anthropic accounts needed by that group without
  removing their current group memberships.
- Expose working OpenAI models through the OpenAI-compatible Chat Completions
  API.
- Add non-Claude-prefixed aliases for working Anthropic models so Cursor can
  import them as OpenAI-compatible models. Use clear aliases such as
  rd-opus-<version>, rd-sonnet-<version>, and rd-haiku-<version>.
- Create a dedicated API key named "RelayDock Composite" for only this group.
- Never display, paste into chat, log, or save the complete API key in a file.
- Do not create models that the connected upstream accounts do not actually
  support. Discover the available model catalog first.

Procedure:
1. Inspect the existing groups, accounts, bindings, routes, and keys read-only.
2. Explain the exact proposed additions and ask me to approve them.
3. Create or update the dedicated Composite group and additive account
   bindings. Do not modify unrelated groups or keys.
4. Add an OpenAI passthrough route for supported gpt-* models.
5. Add explicit alias routes for each supported Anthropic model. Route each
   alias to its real upstream Claude model using the OpenAI-compatible Chat
   Completions interface. Do not expose raw claude-* names to Cursor as the
   preferred imported names.
6. Create the dedicated group-scoped API key. Keep it visible only long enough
   for me to enter it into RelayDock; do not copy it into the Codex task.
7. Test the actual public API base with the new group key:
   - GET /v1/models
   - a non-streaming /v1/chat/completions request for at least one OpenAI model
   - a non-streaming request for at least one Opus or Sonnet alias
   - a streaming request for at least one Anthropic alias, confirming valid SSE
     output and a normal completion marker
8. Report the API base URL, the aliases created, every tested status, and any
   upstream model that was skipped or failed. Redact all secrets.
9. Stop and ask before deleting or replacing anything.

After the administrator work is complete, remind me to add the API base as an
OpenAI Compatible endpoint in RelayDock, save the key there, sync models, test
all models, and import only verified models into Cursor/OpenCode.
```

## Import the result into RelayDock

1. Add an **OpenAI Compatible** endpoint.
2. Enter the public Sub2API API base. RelayDock normalizes an unversioned base
   to its `/v1` API root where appropriate.
3. Paste the new group-scoped key into RelayDock and save it to macOS Keychain.
4. Select **Sync models**, followed by **Test all models**.
5. Import only the verified `rd-*` aliases and working OpenAI models into
   Cursor or OpenCode.

If the Sub2API administrator UI or routing schema differs from the prompt,
Codex must stop and describe the mismatch instead of guessing or overwriting
existing configuration.

---

# 使用 Codex Desktop 为 RelayDock 配置 Sub2API

这份说明适用于已经在本机浏览器中登录 Sub2API 管理后台的管理员。请在
**Codex Desktop** 中使用上面的 Prompt；终端里的 Codex CLI 默认不保证能够访问
已经登录的浏览器会话或桌面 Computer Use 工具。

配置完成后，在 RelayDock 中添加一个 **OpenAI Compatible** Endpoint，填入
Sub2API 的公开 API 地址和新建的 `RelayDock Composite` 专用 Key，然后依次执行
“同步模型”和“测试全部模型”。只把测试通过的 `rd-*` Claude 别名和 OpenAI 模型
导入 Cursor/OpenCode。不要把完整 API Key 粘贴到 Codex 对话、README、日志或仓库中。
