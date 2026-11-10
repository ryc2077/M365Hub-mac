# M365Hub 全功能测试清单

逐项核对，全部打勾才能发 Release。CI（GitHub Workflow）跑自动化部分，
截图由 CI 产物 `gateway-test-evidence` 提供，人工看截图确认 UI。

## Mac 应用

### 启动与登录
- [ ] 冷启动：应用打开，网关自动起来，`/api/admin/session` 通（CI：test-gateway.sh）
- [ ] 登录页正常显示；密码错误有提示
- [ ] 首次登录强制改密流程可用
- [ ] 登录后进聊天页（启动即聊天）

### 聊天
- [ ] 发消息能收到回复（CI：test-account-chat.sh 真实账号）
- [ ] 模型选择器默认 gpt-5.6-reasoning，可切换
- [ ] 账号选择器：轮询 / pin 单账号
- [ ] 生成图片（flux-4/flux-3）能出图
- [ ] 上传图片 / 文件可用
- [ ] 数学公式渲染（行内 + 行间）
- [ ] 助手消息可复制（全部复制 + 选中复制）
- [ ] 历史对话：新建、切换、删除

### 仪表盘
- [ ] 账号数 / 活跃 / 冷却 / 在途 / 熔断 / 监听地址 / Key 数 / 代理数显示
- [ ] 配额 bestHeadroom 显示

### 账号
- [ ] 账号列表显示（CI：test-account-chat.sh）
- [ ] PKCE 添加账号流程能走到浏览器授权（CI：test-real-account-pkce.sh）
- [ ] 刷新全部账号状态
- [ ] 导出账号（明文 JSON，含刷新令牌警告）
- [ ] 导入账号
- [ ] 删除账号

### API Keys
- [ ] 列表显示（只显示前 12 位）
- [ ] 新建 Key：完整密钥只显示一次 + 已复制到剪贴板 + 复制按钮
- [ ] 删除 Key

### 代理池
- [ ] 列表、添加、移除

### 用量统计
- [ ] 7 日请求数 / 命中率 / 节省 Token / 输入 / 输出显示

### 模型
- [ ] 模型列表显示

### 系统
- [ ] 版本显示

### 设置
- [ ] 深色模式切换
- [ ] 修改管理员密码
- [ ] 退出登录

### 本地记忆（新增，重点）
- [ ] 记忆列表显示：key、轮次、字数、已压缩
- [ ] 点一条记忆能看到具体内容：摘要 + 全部轮次（role + content）
- [ ] 删除一条记忆
- [ ] 空记忆时显示“还没有本地记忆”

## 安卓应用

- [ ] 本地记忆列表能显示（修 key 名：网关返回 `memories`，不是 `keys`/`items`）
- [ ] 点一条记忆能看到具体内容（摘要 + 轮次），不再只弹字节数 toast

## 网关（CI 覆盖）

- [ ] `GET /api/local-memory` 返回 `memories` 列表
- [ ] `GET /api/local-memory?key=X` 返回 `summary` + `turns`
- [ ] `DELETE /api/local-memory?key=X` 删除
- [ ] CodeX 工具调用：R3–R9、P5、P8（CI：test-codex-mac.sh）
- [ ] 桌面端流程：gpt-5.6-reasoning 工具调用（CI：test-desktop-flow.sh）
- [ ] 远程压缩 v2：compaction_trigger → 单个 compaction 项（回归测试 + CI）
- [ ] choices 信封：未声明/畸形信封走纠正重问，不漏原始 JSON（回归测试）

## 发布前
- [ ] CI 全绿（build + 全部测试步骤）
- [ ] 截图逐张看过：启动、登录、聊天、记忆列表、记忆详情
- [ ] Release 产物包内网关 md5 与所推二进制一致
