# LatticeLens 1.0.0-local（h-index 修复包）

这是当前源码的同 Mac 本地 ad-hoc 包。请先核对 `manifest-v1.0.json` 和
`SHA256SUMS.txt`，再从 DMG 安装。此次修复限制 h-index 本地 fallback 在
INSPIRE 的 page 41 之前停止，避免已知 HTTP 400 让作者索引整体不可见。

该包没有 Developer ID 签名或公证；DMG smoke 只使用项目内 fixture/no-network
副本，不会写入 `/Applications`、真实 Application Support、Keychain 或真实科研资料。
回滚时退出 app 并移除用户选择的 app 副本即可，不要删除真实 library。
