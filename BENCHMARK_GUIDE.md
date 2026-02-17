# LFM vs OFM Benchmark 测试指南

本文档总结 LFM 与 OFM 的 benchmark 测试方案，并给出**详细操作步骤**，供在 Windows 远程机器上实际跑测使用。

---

## 〇、快速开始：具体怎么做

**核心思路**：分别运行两个项目的可执行文件，记录每帧耗时（ms）和实际帧率（FPS），填入表格对比。

- **OFM**：自带 GPU 耗时统计，运行后会在控制台打印各阶段耗时。
- **LFM**：无内置统计，需用 NVIDIA Nsight Systems 或手动计时。

下面从环境已 build 成功开始，给出完整操作流程。

---

## 一、运行与测时操作步骤

### 1.1 运行 OFM（带内置 Profiler）

OFM 已集成 `GPUTimer`，每帧会在控制台打印各阶段耗时。

**步骤：**

1. 打开 **命令提示符（cmd）** 或 **PowerShell**。
2. 进入 OFM 的 `dynamic_obstacle` 目录：
   ```cmd
   cd <ofm_dynamic 路径>\proj\dynamic_obstacle
   ```
   例如：`cd D:\projects\ofm_dynamic\proj\dynamic_obstacle`
3. 运行可执行文件：
   ```cmd
   .\build\dynamic_obstacle.exe
   ```
4. 程序会弹出窗口显示流体模拟，**控制台**会持续输出类似：
   ```
   [Profiler] Advection: 2.3 ms
   [Profiler] Projection 1: 1.8 ms
   [Profiler] Marching Backward flowmap: ...
   [Profiler] Marching Forward flowmap: ...
   [Profiler] Impulse reconstruction: ...
   [Profiler] BFECC: ...
   [Profiler] Projection 2: ...
   [Profiler] UpdateBoundaryCondition: ...   (仅动态固体时)
   ```
5. 让程序运行约 **30–60 秒**，观察控制台输出稳定后，记录或截图保存。
6. 关闭窗口结束程序。

**保存输出到文件：**

```cmd
.\build\dynamic_obstacle.exe > ofm_benchmark_log.txt 2>&1
```

若为 GUI 程序，控制台可能不重定向，可改用：

```powershell
Start-Process -FilePath ".\build\dynamic_obstacle.exe" -NoNewWindow -Wait -RedirectStandardOutput ofm_log.txt -RedirectStandardError ofm_err.txt
```

或直接观察控制台并手动记录/截图。

**提示**：若运行后看不到控制台输出，可能是程序以 GUI 方式启动。可尝试：
- 从 **cmd** 或 **PowerShell** 直接运行（不要双击 exe），这样控制台会保持打开；
- 或在 Visual Studio 中运行，从「输出」窗口查看。

---

### 1.2 运行 LFM（无内置 Profiler）

LFM 没有内置耗时统计，需要用外部工具或手动计时。

**方法 A：NVIDIA Nsight Systems（推荐）**

1. 确认已安装 [NVIDIA Nsight Systems](https://developer.nvidia.com/nsight-systems)（随 CUDA 或单独安装）。
2. 在 cmd 中进入 LFM 的 `sim_render` 目录：
   ```cmd
   cd <lfm 路径>\proj\sim_render
   ```
3. 使用 `nsys` 采集 profile：
   ```cmd
   nsys profile -o lfm_profile --stats=true .\build\sim_render.exe
   ```
4. 程序会正常启动并运行；运行约 **30–60 秒** 后关闭窗口结束程序。
5. 结束后在当前目录生成 `lfm_profile.nsys-rep` 和 `lfm_profile.txt`。
6. 打开 `lfm_profile.txt` 查看 CUDA kernel 耗时汇总（如 `AdvectN2X`、`ProjectAsync` 相关 kernel 等）。

**方法 B：手动计时（简单但粗糙）**

1. 运行程序：
   ```cmd
   cd <lfm 路径>\proj\sim_render
   .\build\sim_render.exe
   ```
2. 用秒表或手机计时，记录运行约 60 秒内完成的帧数（可从窗口标题或 UI 若有帧数显示）。
3. 估算：`FPS ≈ 总帧数 / 60`，`ms/frame ≈ 1000 / FPS`。

**方法 C：任务管理器 / GPU-Z**

1. 打开任务管理器 → 性能 → GPU，或使用 GPU-Z。
2. 运行 LFM，观察 GPU 利用率与显存占用。
3. 可得到相对性能印象，但无法精确到每帧 ms。

---

### 1.3 运行前检查

| 检查项 | 说明 |
|--------|------|
| 工作目录 | 必须在 `proj/sim_render`（LFM）或 `proj/dynamic_obstacle`（OFM）下运行，否则找不到 `config/` |
| 配置文件 | LFM 默认加载 `config/deltawing.json`，OFM 默认 `config/dynamic_obstacle.json` |
| 子模块 | 两个项目都需执行 `git submodule update --init --recursive` |
| GPU | 需 NVIDIA GPU，驱动支持 CUDA 12.x |

**Build 命令（若需重新编译）：**

```cmd
:: LFM
cd <lfm 路径>\proj\sim_render
xmake build

:: OFM（在 proj 目录下 build，会编译 dynamic_obstacle 等）
cd <ofm_dynamic 路径>\proj
xmake build
```

编译完成后：
- LFM 可执行文件：`lfm/proj/sim_render/build/sim_render.exe`
- OFM 可执行文件：`ofm_dynamic/proj/dynamic_obstacle/build/dynamic_obstacle.exe`

运行前需先 `cd` 到对应 `proj/sim_render` 或 `proj/dynamic_obstacle` 目录，否则程序找不到 `config/` 和 `assets/`。

---

### 1.4 建议测试顺序

| 顺序 | 测试 | 预计时间 |
|------|------|----------|
| 1 | 运行 OFM dynamic_obstacle，记录控制台输出 | 1–2 分钟 |
| 2 | 运行 LFM deltawing，用 nsys 或手动计时 | 2–3 分钟 |
| 3 | 修改配置（见下节）后重复测试 | 视修改而定 |

---

## 二、修改配置做不同场景测试

### 2.1 修改 LFM 配置

配置文件：`lfm/proj/sim_render/config/deltawing.json`

**常用修改：**

```json
"lfm": {
    "reinit_every": 5,        // 改为 1、3、5 对比
    "rk_order": 4,            // 改为 2 或 4 对比
    ...
},
"driver": {
    "total_frame": -1,        // -1 表示无限运行；可改为 300 跑 300 帧后退出
    "frame_rate": 20,         // 改为 30 与 OFM 对齐
    "steps_per_frame": 5      // 应等于 reinit_every
}
```

**注意**：`steps_per_frame` 必须等于 `reinit_every`，否则逻辑会错。

### 2.2 修改 OFM 配置

配置文件：`ofm_dynamic/proj/dynamic_obstacle/config/dynamic_obstacle.json`

**常用修改：**

```json
"ofm": {
    "use_dynamic_solid": true,   // 旋转八面体场景保持 true
    "use_static_solid": false,
    ...
},
"driver": {
    "total_frame": -1,
    "frame_rate": 30
}
```

**若要做“静态固体”对比（需额外准备）：**

- 将 `use_dynamic_solid` 设为 `false`，`use_static_solid` 设为 `true`。
- 需从 LFM 复制 `deltawing` 的 `solid_sdf.npy`、`init_u_*.npy` 等资源，并修改 `solid_sdf_path`。具体步骤见后文「公平对比配置」。

---

## 三、如何记录和整理数据

### 3.1 从 OFM 控制台提取的数据

OFM 的 profiler 会输出各阶段耗时（单位 ms）。典型需要记录：

| 阶段 | 含义 |
|------|------|
| Advection | 平流 |
| Projection 1 | Advance 中的压力投影 |
| Marching Backward flowmap | 后向 Flow Map 积分 |
| Marching Forward flowmap | 前向 Flow Map 积分 |
| Impulse reconstruction | Pullback 重建 |
| BFECC | BFECC 误差修正 |
| Projection 2 | Reinit 后的压力投影 |
| UpdateBoundaryCondition | 动态边界更新（仅动态固体时） |
| Rebuild Projection Matrix | Poisson 矩阵重建（仅动态固体时） |

**物理总耗时** ≈ Advection + Projection 1 + (Marching Backward + Marching Forward + Impulse + BFECC + Projection 2) + 若启用动态固体则加上 UpdateBoundary 等。

### 3.2 数据记录模板

建议用 Excel 或表格记录，例如：

| 场景 | 方法 | 分辨率 | reinit_every | FPS | ms/frame | Advance(ms) | Reinit(ms) | 备注 |
|------|------|--------|--------------|-----|----------|-------------|------------|------|
| Delta wing | LFM | 256×128×128 | 5 | | | | | |
| 旋转八面体 | OFM | 256×128×128 | 1 | | | | | |
| ... | | | | | | | | |

- **FPS**：实际帧率（若程序有显示）或 1000/ms/frame。
- **ms/frame**：每帧总耗时。
- **Advance(ms)**：LFM 为 5 次 Advance 总和；OFM 为 Advection + Projection 1。
- **Reinit(ms)**：Flow Map + BFECC + Projection 2 等。

---

## 四、公平对比配置（可选，需改代码）

若要严格对比 LFM 与 OFM 在**同一 Delta wing 静态固体场景**下的表现，需要让 OFM 也跑该场景。

**现状**：OFM 的 `ofm_init.cu` 目前**不**从文件加载初始速度场（`init_u`），只支持从 SDF 加载静态固体边界。因此需要：

1. 从 LFM 复制 `assets/deltawing/` 到 OFM 的 `assets/deltawing/`。
2. 在 OFM 的 `InitOFMAsync` 中增加与 LFM 类似的逻辑：从 `init_u_x_path`、`init_u_y_path`、`init_u_z_path` 读取 `.npy` 并写入 `init_u_x_`、`init_u_y_`、`init_u_z_`。
3. 在 `OFMConfiguration` 中增加上述路径字段，并在配置 JSON 中填写。

**简化做法**：若暂不实现上述改动，可先做**场景级**对比：
- **LFM**：Delta wing（静态固体 + 初始速度场）
- **OFM**：旋转八面体（动态固体）

两者分辨率均为 256×128×128，可对比「每帧物理总耗时」和「实际 FPS」，并在报告中说明场景差异。

---

## 五、论文与 Thesis 中的 Benchmark 来源

### 1.1 LFM 论文（SIGGRAPH 2025）

**来源**：Sun et al., "Leapfrog Flow Maps for Real-Time Fluid Simulation", ACM TOG 2025  
**项目页**：https://yuchen-sun-cg.github.io/projects/lfm/

论文中提到的实验场景：

| 场景 | 描述 | 特点 |
|------|------|------|
| **Burning fire ball** | 燃烧火球 | 火焰、涡旋结构 |
| **Delta wingtip vortices** | 三角翼翼尖涡 | 翼尖涡、涡量保持 |
| **Helical trail behind wind turbine** | 风力机尾迹螺旋 | 螺旋涡结构 |
| **Two connecting vortex rings** | 两个相连涡环 | 涡环相互作用 |

**性能指标**：
- 分辨率：**256 × 128 × 128**（tile_dim [32, 16, 16]）
- 硬件：NVIDIA RTX 4090
- 目标：实时（real-time）

### 1.2 OFM Thesis（Georgia Tech MSCS）

**来源**：Yutong Sun, "One-Step Flow Maps for Real-time Fluid Simulation with Dynamic Boundaries"  
**文件**：`ofm_dynamic/Yutong_Sun_MSCS_Thesis.pdf`

Thesis 中的实验场景：

| 场景 | 描述 | 特点 |
|------|------|------|
| **Rotating octahedron** | 旋转八面体与流体交互 | 动态边界、体素化 |
| **Dynamic obstacle** | 任意运动固体 | 实时体素化管线 |

**性能指标**：
- 分辨率：**256 × 128 × 128**（与 LFM 一致）
- 硬件：NVIDIA RTX 4080（笔记本）
- 帧率：30 FPS

---

## 二、项目现有配置与场景

### 2.1 LFM 项目

| 配置项 | 值 | 说明 |
|--------|-----|------|
| 场景 | `deltawing` | 三角翼 + 静态固体 SDF |
| tile_dim | [32, 16, 16] | → 256×128×128 |
| frame_rate | 20 | 目标帧率 |
| steps_per_frame | 5 | 每帧 Advance 次数 |
| reinit_every | 5 | 每 5 步 Reinit |
| rk_order | 4 | RK4 积分 |
| 静态固体 | tri_plate.obj + solid_sdf.npy | 三角翼 SDF |

**配置文件**：`proj/sim_render/config/deltawing.json`

### 2.2 OFM 项目

| 配置项 | 值 | 说明 |
|--------|-----|------|
| 场景 | `dynamic_obstacle` | 旋转八面体 |
| tile_dim | [32, 16, 16] | → 256×128×128 |
| frame_rate | 30 | 目标帧率 |
| use_dynamic_solid | true | 动态边界 |
| 动态固体 | octahedron.obj | 旋转角速度 [0, 150, 0] |

**配置文件**：`proj/dynamic_obstacle/config/dynamic_obstacle.json`

---

## 三、建议的 Benchmark 测试矩阵

### 3.1 核心对比场景（必测）

| 编号 | 场景 | LFM | OFM | 目的 |
|------|------|-----|-----|------|
| **B1** | Delta wing（静态固体） | ✓ 原生支持 | ✓ 需关动态固体、用 SDF | 公平对比算法本身 |
| **B2** | 旋转八面体（动态固体） | ✗ 不支持 | ✓ 原生支持 | 展示 OFM 动态边界能力 |
| **B3** | 空域（无固体） | ✓ 可配置 | ✓ 可配置 | 纯流体性能基线 |

### 3.2 分辨率扩展（建议）

| 编号 | 分辨率 | tile_dim | 网格点数 | 说明 |
|------|--------|----------|----------|------|
| R1 | 128×64×64 | [16, 8, 8] | ~52万 | 轻量 |
| R2 | 256×128×128 | [32, 16, 16] | ~420万 | 论文默认 |
| R3 | 512×256×256 | [64, 32, 32] | ~3350万 | 高分辨率 |

### 3.3 LFM 参数扫描（可选）

| 参数 | 取值 | 说明 |
|------|------|------|
| reinit_every | 1, 3, 5 | 对比 One-Step vs Leapfrog |
| rk_order | 2, 4 | RK2 vs RK4 |
| frame_rate | 20, 30, 60 | 不同帧率目标 |

---

## 四、建议测量的指标

### 4.1 性能指标

| 指标 | 单位 | 说明 |
|------|------|------|
| **FPS** | 帧/秒 | 实际帧率 |
| **ms/frame** | 毫秒 | 每帧耗时 |
| **Advance 耗时** | ms | Advection + Projection |
| **Reinit 耗时** | ms | Flow Map + BFECC + Projection |
| **总物理步耗时** | ms | 不含渲染 |
| **内存占用** | GB | GPU 显存 |

### 4.2 精度/质量指标（若需）

| 指标 | 说明 |
|------|------|
| **涡量保持** | 涡量范数随时间变化 |
| **能量衰减** | 动能衰减曲线（可参考 Taylor-Green） |
| **BFECC 误差** | 误差场范数 |

### 4.3 动态边界专用（OFM）

| 指标 | 说明 |
|------|------|
| **UpdateBoundary 耗时** | 体素化 + 边界更新 |
| **BuildAsync 耗时** | Poisson 矩阵重建 |

---

## 五、标准流体 Benchmark 补充建议

若需与通用 CFD 基准对齐，可考虑：

### 5.1 Taylor-Green Vortex Decay

- **用途**：验证不可压 NS 求解器、能量耗散
- **初始条件**：解析形式，周期边界
- **指标**：动能衰减曲线、与 DNS 或高精度参考对比
- **注意**：LFM/OFM 为 MAC 网格、有壁面，需做适当适配（如周期边界或大域近似）

### 5.2 涡环碰撞（Vortex Ring Collision）

- **用途**：涡量保持、复杂涡结构
- **与论文**：对应 "Two connecting vortex rings"
- **实现**：可从 LFM 的 init_u 或类似场景扩展

### 5.3 通道流（Channel Flow）

- **用途**：壁面边界、入口速度
- **与论文**：与 delta wing 入口设置类似

---

## 六、实验设计建议

### 6.1 公平对比的前提

1. **相同分辨率**：统一 256×128×128
2. **相同硬件**：同一 GPU（如 RTX 4090 或 4080）
3. **相同场景**：B1（Delta wing 静态）下，LFM 与 OFM 均用静态 SDF
4. **相同帧率目标**：如 30 FPS，便于比较每帧耗时

### 6.2 LFM 与 OFM 的等价设置

为公平比较算法本身，建议：

| 设置 | LFM | OFM |
|------|-----|-----|
| 分辨率 | 256×128×128 | 256×128×128 |
| 场景 | Delta wing（静态固体） | Delta wing（use_dynamic_solid=false, use_static_solid=true） |
| 帧率目标 | 30 | 30 |
| LFM reinit_every | 1（与 OFM 对齐）或 5（论文默认） | N/A |

**注意**：OFM 默认 One-Step，LFM 若设 `reinit_every=1` 可近似 One-Step，但 LFM 的 Advance 逻辑仍与 OFM 不同（Leapfrog 的 mid_dt 策略）。

### 6.3 测试流程建议

1. **基线**：空域、256×128×128，测 FPS 和 ms/frame
2. **静态固体**：Delta wing，LFM vs OFM（均用 SDF）
3. **动态固体**：仅 OFM，旋转八面体，记录 UpdateBoundary 等耗时
4. **分辨率扩展**：128³、256³、512³，绘制性能曲线
5. **LFM 参数**：reinit_every=1,3,5 对比

---

## 七、数据记录模板

建议用表格记录，便于写报告：

| 场景 | 方法 | 分辨率 | reinit_every | FPS | ms/frame | Advance(ms) | Reinit(ms) | 备注 |
|------|------|--------|--------------|-----|----------|-------------|------------|------|
| Delta wing | LFM | 256×128×128 | 5 | | | | | |
| Delta wing | OFM | 256×128×128 | 1 | | | | | |
| 旋转八面体 | OFM | 256×128×128 | 1 | | | | UpdateBoundary | |
| ... | | | | | | | | |

---

## 八、参考文献与资源

- **LFM 论文**：Sun et al., "Leapfrog Flow Maps for Real-Time Fluid Simulation", ACM TOG 2025
- **LFM 项目页**：https://yuchen-sun-cg.github.io/projects/lfm/
- **OFM Thesis**：Yutong Sun, "One-Step Flow Maps for Real-time Fluid Simulation with Dynamic Boundaries", Georgia Tech MSCS
- **Taylor-Green 基准**：常用于不可压 NS 验证，见 FluidSim、Nektar++ 等文档
