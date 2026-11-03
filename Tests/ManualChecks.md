# macOS 15 手动功能验证

`make test` 验证纯逻辑和动作结果处理，不代表已实测跨应用打开菜单。核心功能需要在图形桌面中由用户手动授予 **TrayBridge** 辅助功能权限后验证；无需给测试宿主授权，也无需录屏权限。

## 先确认运行副本和授权

1. 退出旧 TrayBridge 副本，安装当前版本的 `TrayBridge.app` 到固定的「应用程序」位置，再从该位置启动。
2. 如系统辅助功能开关已打开但仍读不到项目，只移除旧 TrayBridge 的辅助功能条目，添加新安装的 `.app` 并授权，然后通过菜单重新启动。不要重置全部应用权限或修改系统安全设置。
3. 打开应用的原生诊断窗口，记录运行路径、版本、PID、信任状态及每个目标进程的实际 AX 返回。仅看到系统设置的开关为「开」不算读取成功。

## 基础菜单与刘海场景

1. 运行 `bash Scripts/build-fixture.sh`，仅构建 `work/fixtures/TrayBridgeFixture.app`。用 `open work/fixtures/TrayBridgeFixture.app` 启动，然后打开 TrayBridge。两个应用都通过 `.app` 启动，不直接运行裸二进制。
2. 在 TrayBridge 原生菜单中检查测试宿主的三个独立项目：原生菜单按钮、回调按钮、只有圆点图标且未设置文字/描述的按钮。第三项应仍可通过应用名称等回退名称选中。
3. 选择原生菜单项目，应显示宿主的原生菜单；选择“记录菜单点击”。选择两个回调项目，均应弹出“已收到操作”窗口。检查 `work/fixtures/events.log` 分别包含 `native-menu opened`、`native-menu action selected`、`named-button clicked`、`unnamed-button clicked`，且每次选择只记录一次回调。
4. 通过宿主原生菜单“退出测试宿主”退出，再用 `open work/fixtures/TrayBridgeFixture.app --args --crowded` 启动。它增加 20 个独立命名项目。确认菜单栏确实拥挤且存在被刘海遮住的项目；通过 **⌃⌥Space** 打开 TrayBridge，选择其中被遮住的“独立溢出测试 NN”。应弹出反馈窗口，日志出现对应 `crowded-NN clicked`。只有此步在带刘海机器成功，才可记作刘海场景实测通过。
5. 测试有外接屏、移动显示器排列、切换前台应用、宿主退出/重启后的列表刷新。旧项目不可误触发到另一个项目。检查没有重复菜单项；无有效几何信息的项目仍应保留。
6. 用实际日常应用各选一个菜单栏项目测试。某些 Electron 应用忽略 `AXPress`，即便系统报告动作成功，也可能没有可见响应；这些应用需单独记录兼容性，不能以 fixture 成功推断全部兼容。右键/Option 动作只对实现 `AXShowMenu` 的应用有效。

## 1.0.1：后启动和延迟创建项目

1. 从宿主菜单退出测试宿主，保持 TrayBridge 运行。确认其清单不再包含宿主的旧项目。
2. 此时再执行 `open work/fixtures/TrayBridgeFixture.app`，然后打开 TrayBridge 菜单；若首次扫描发生在宿主就绪之前，稍等后重新打开菜单，确认三个项目最终出现并能分别触发。记录从宿主启动到发现项目所需时间，以及诊断中的实际 AX 返回。
3. 再退出宿主，执行 `open work/fixtures/TrayBridgeFixture.app --args --delay-seconds 8`。这次宿主进程先启动，菜单栏项目延迟创建；在延迟期间打开 TrayBridge 菜单，并在 8 秒之后再次打开。项目创建后应能被后续扫描发现，不需要退出 TrayBridge 或重新授权。
4. 让菜单保持打开跨过图标创建时刻，再关闭重开，确认新增项目可见；打开期间已有项目的选择不应被重排导致误点。对已消失的旧项目选择应提示或安全忽略，不能误触发其他应用。
5. 退出并重启宿主，重复上述操作。检查列表没有重复项，诊断不把旧进程 PID 的结果当作新进程。最后用一个真实日常应用重复「先开 TrayBridge，后开目标应用」流程；fixture 通过不能代替真实应用兼容性验证。

测试完成后从宿主菜单退出。日志仅记录 fixture 的测试动作，不包含其他应用内容；可删除 `work/fixtures` 清理。不要把本文件当作已经执行的验收记录。
