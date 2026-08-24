# iOS TestFlight 构建说明：0.5.24+11038

本次仅更新 iOS 构建号，不创建 GitHub/Gitee Release，也不改变营销版本号

## 扫码实验结论

- 在 iPhone 15、同一张稳定面单、连续 10 秒窗口中，metadata 识别 292 次，约 29.3 次/秒，P50 间隔 33ms
- 同一条件下，Vision 完成 147 次，约 14.8 次/秒，P50 间隔 67ms；Vision 单次处理平均 24.1ms，P95 为 29ms
- 两条路径本轮窗口识别成功率均为 100%
- 发布逻辑保持 metadata 优先，Vision 仅作为 metadata 无近期结果时的低频兜底

## 本次 TestFlight 验证重点

- 使用稳定面单确认连续扫码结果和重复条码门控
- 验证 metadata 暂停或无结果时 Vision 兜底是否恢复识别
- 重点回归 iPhone 6S 等老设备的扫码兼容性和系统提示
- 检查诊断日志是否包含设备机型、机型标识、系统版本和扫码路径统计
