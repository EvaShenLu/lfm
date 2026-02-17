# LFM 与 OFM 项目对比：OFM 在 LFM 基础上的改动

本文档详细对比 LFM（Leapfrog Flow Maps）与 OFM（One-Step Flow Maps）两个项目，说明 OFM 在 LFM 基础上做了哪些改动。

---

## 一、项目概述

| 项目 | 全称 | 定位 |
|------|------|------|
| **LFM** | Leapfrog Flow Maps | 实时流体模拟，蛙跳时间积分 |
| **OFM** | One-Step Flow Maps | 实时流体模拟 + 动态边界，单步积分 |

OFM 基于 LFM 实现，主要面向：
1. **动态边界**：与任意运动固体实时交互
2. **效率优化**：One-Step 积分方案，减少每帧计算量

---

## 二、核心算法改动

### 2.1 时间积分方案：Leapfrog → One-Step

| 维度 | LFM | OFM |
|------|-----|-----|
| **reinit_every_** | 3~5（可配置） | 隐式 1（每帧一次 Advance + Reinit） |
| **每帧 Advance 次数** | `reinit_every_` 次 | 1 次 |
| **每帧 Reinit 次数** | 1 次 | 1 次 |
| **时间步长** | `dt = 1/(frame_rate × reinit_every_)` | `dt = 1/frame_rate` |

**LFM 主循环**（`proj/sim_render/physics.cu`）：
```cpp
float dt = 1.0f / (frame_rate * lfm_.reinit_every_);
for (int i = 0; i < lfm_.reinit_every_; i++)
    lfm_.AdvanceAsync(dt, streamToRun);
lfm_.ReinitAsync(dt, streamToRun);
```

**OFM 主循环**（`proj/dynamic_obstacle/physics.cu`）：
```cpp
float dt = 1.0f / static_cast<float>(frame_rate);
ofm_.AdvanceAsync(dt, streamToRun);
ofm_.ReinitAsync(dt, streamToRun);
```

---

### 2.2 Advance 阶段：可变 Leapfrog → 固定半步

| 维度 | LFM | OFM |
|------|-----|-----|
| **mid_dt** | 随 `step_ % reinit_every_` 变化：0.5dt / dt / 2dt | 固定 `0.5 * dt` |
| **src_u** | 随步数在 init_u 与 mid_u[i] 间切换 | 固定 `init_u` |
| **last_proj_u** | 同上 | 固定 `init_u` |

**LFM Advance 逻辑**（`src/lfm/lfm.cu`）：
```cpp
if (step_ % reinit_every_ == 0) {
    mid_dt = 0.5f * _dt;
    last_proj_u = init_u;  src_u = init_u;
} else if (step_ % reinit_every_ == 1) {
    mid_dt = _dt;
    last_proj_u = mid_u_[0];  src_u = mid_u_[0];
} else {
    mid_dt = 2.0f * _dt;
    last_proj_u = mid_u_[step_ % reinit_every_ - 1];
    src_u = mid_u_[step_ % reinit_every_ - 2];
}
```

**OFM Advance 逻辑**（`src/ofm/ofm.cu`）：
```cpp
float mid_dt = 0.5f * _dt;
std::shared_ptr<...> last_proj_u = init_u_;
std::shared_ptr<...> src_u = init_u_;
// 无分支，始终使用 init_u
```

---

### 2.3 中间速度场存储：数组 → 单份

| 维度 | LFM | OFM |
|------|-----|-----|
| **mid_u 结构** | `mid_u_x_[i]`, `mid_u_y_[i]`, `mid_u_z_[i]`（i = 0..reinit_every_-1） | `mid_u_x_`, `mid_u_y_`, `mid_u_z_`（单份） |
| **内存** | `reinit_every_ × 3` 个速度场 | 3 个速度场 |

**LFM 分配**（`src/lfm/lfm.cu`）：
```cpp
mid_u_x_.resize(reinit_every_);
for (int i = 0; i < reinit_every_; i++) {
    mid_u_x_[i] = std::make_shared<DHMemory<float>>(x_voxel_num);
    // ...
}
```

**OFM 分配**（`src/ofm/ofm.cu`）：
```cpp
mid_u_x_ = std::make_shared<DHMemory<float>>(x_voxel_num);
mid_u_y_ = std::make_shared<DHMemory<float>>(y_voxel_num);
mid_u_z_ = std::make_shared<DHMemory<float>>(z_voxel_num);
```

---

### 2.4 Reinit 阶段：多步积分 → 单步积分

| 维度 | LFM | OFM |
|------|-----|-----|
| **后向 Flow Map** | 循环 `reinit_every_` 次，从 i=reinit_every_-1 到 0 | 单次 `RKAxisAsync`，用 `mid_u_` |
| **前向 Flow Map** | 循环 `reinit_every_` 次，从 i=0 到 reinit_every_-1 | 单次 `RKAxisAsync`，用 `mid_u_` 和 `-dt` |
| **积分阶数** | RK2 或 RK4（`rk_order_`） | TVDRK3（固定） |

**LFM Reinit 中 Flow Map 积分**（`src/lfm/lfm.cu`）：
```cpp
for (int i = reinit_every_ - 1; i >= 0; i--) {
    RKAxisAsync(rk_order_, psi_x_, T_x_, ..., mid_u_x_[i], mid_u_y_[i], mid_u_z_[i], _dt, ...);
    // ...
}
for (int i = 0; i < reinit_every_; i++) {
    RKAxisAsync(rk_order_, phi_x_, F_x_, ..., mid_u_x_[i], ..., -_dt, ...);
    // ...
}
```

**OFM Reinit 中 Flow Map 积分**（`src/ofm/ofm.cu`）：
```cpp
RKAxisAsync(*psi_x_, *T_x_, ..., *mid_u_x_, *mid_u_y_, *mid_u_z_, ..., _dt, _stream);
RKAxisAsync(*psi_y_, *T_y_, ...);
RKAxisAsync(*psi_z_, *T_z_, ...);
RKAxisAsync(*phi_x_, *F_x_, ..., -_dt, _stream);
RKAxisAsync(*phi_y_, *F_y_, ...);
RKAxisAsync(*phi_z_, *F_z_, ...);
```

---

### 2.5 Flow Map 积分器：RK2/RK4 → TVDRK3

| 维度 | LFM | OFM |
|------|-----|-----|
| **积分器** | RK2 或 RK4（可配置 `rk_order_`） | TVDRK3（TVD Runge-Kutta 3 阶） |
| **实现** | `RKAxisAsync` 根据 `rk_order_` 选择 kernel | `RKAxisAsync` 固定调用 `TVDRK3AxisKernel` |

OFM 的 TVDRK3 在 `ofm_util.cu` 中实现，相比 RK2 有更好的稳定性和精度表现。

---

## 三、新增功能：动态边界

### 3.1 边界来源

| 边界类型 | LFM | OFM |
|----------|-----|-----|
| **壁面** | `SetWallBcAsync` | `SetWallBcAsync` |
| **静态固体** | `SetBcByPhiAsync`（SDF） | `SetBcByPhiAsync`（SDF） |
| **动态固体** | 不支持 | `SetBcBySurfaceAsync`（体素 + 速度纹理） |

### 3.2 动态边界实现

OFM 新增：

1. **数据结构**（`src/ofm/ofm.h`）：
   ```cpp
   bool use_dynamic_solid_;
   cudaSurfaceObject_t voxel_tex_;      // 体素化固体
   cudaSurfaceObject_t velocity_tex_;    // 固体表面速度
   float voxelized_velocity_scaler_;
   ```

2. **UpdateBoundary**（`src/ofm/ofm.cu`）：
   - 每帧（首帧除外）在 Advance 前调用
   - `SetBcBySurfaceAsync`：从 `voxel_tex_`、`velocity_tex_` 设置边界
   - `SetCoefByIsBcAsync`：更新 Poisson 系数
   - `amgpcg_.BuildAsync`：重建投影矩阵

3. **SetBcBySurfaceAsync**（`src/ofm/ofm_util.cu`）：
   - 遍历网格，读取 `voxel_tex_`
   - 若为固体，标记边界并从 `velocity_tex_` 读取速度
   - 固体内部及表面网格点设为 Dirichlet 边界

### 3.3 体素化管线

OFM 依赖外部体素化管线（如 Vulkan 渲染管线）生成：
- `voxel_tex_`：体素占用（0/1）
- `velocity_tex_`：固体表面速度（R32G32B32A32）

这些纹理通过 `importExtImage` 与 CUDA 共享，在 `physics.cu` 的 `initExternalMem` 中完成绑定。

---

## 四、移除或简化的功能

### 4.1 烟雾场

| 维度 | LFM | OFM |
|------|-----|-----|
| **烟雾场** | 支持多烟雾场（`num_smoke_`, `smoke_`, `init_smoke_` 等） | 未实现 |
| **Reinit 中烟雾更新** | 有（Pullback + BFECC） | 无 |

LFM 在 Reinit 末尾有烟雾场更新逻辑，OFM 中已删除。

### 4.2 配置与参数

| 参数 | LFM | OFM |
|------|-----|-----|
| **reinit_every_** | 有，可配置 | 无（隐式 1） |
| **rk_order_** | 有，2 或 4 | 无，固定 TVDRK3 |
| **Poisson 求解** | 可配置迭代/容差 | `solve_by_tol_=false`, `max_iter_=6` |

---

## 五、工程与项目结构

### 5.1 目录与命名

| 项目 | 核心源码 | 示例工程 |
|------|----------|----------|
| **LFM** | `src/lfm/`（lfm.cu, lfm_util.cu, lfm_init.cu） | `proj/sim_render/` |
| **OFM** | `src/ofm/`（ofm.cu, ofm_util.cu, ofm_init.cu） | `proj/dynamic_obstacle/` |

### 5.2 依赖与构建

- 两者均使用 AMGPCG 求解 Poisson
- OFM 的 `dynamic_obstacle` 依赖 Vulkan 渲染与体素化管线
- LFM 的 `sim_render` 为纯流体渲染示例

---

## 六、接口差异

### 6.1 函数签名

部分工具函数在 OFM 中显式传入更多参数，例如：

| 函数 | LFM | OFM |
|------|-----|-----|
| `AdvectN2XAsync` | `(dst, src, u_x, u_y, u_z, dx, dt, stream)` | `(dst, tile_dim, src, u_x, u_y, u_z, dx, dt, stream)` |
| `PullbackAxisAsync` | 类似 | 显式传入 `tile_dim`, `axis_tile_dim`, `grid_origin`, `dx` |
| `AddFieldsAsync` | `(dst, axis_tile_dim, src1, src2, coef, stream)` | `(dst, tile_dim, src1, src2, coef, stream)` |

### 6.2 ProjectAsync 数据流

两者 Projection 流程一致，但 OFM 的 `ProjectAsync` 明确对 `tmp_u_` 做：
- 设置边界
- 计算散度
- 求解 Poisson
- 应用压力梯度

逻辑与 LFM 相同，只是变量命名和引用方式略有不同。

---

## 七、改动总结表

| 类别 | 改动类型 | 说明 |
|------|----------|------|
| **时间积分** | 简化 | Leapfrog 多步 → One-Step，每帧 1 次 Advance + 1 次 Reinit |
| **中间速度** | 简化 | `mid_u_[i]` 数组 → 单份 `mid_u_` |
| **Advance 逻辑** | 简化 | 去掉 step 分支，固定 mid_dt=0.5dt、src=init_u |
| **Flow Map 积分** | 简化 | 多步循环 → 单步，使用 mid_u |
| **积分器** | 替换 | RK2/RK4 → TVDRK3 |
| **动态边界** | 新增 | UpdateBoundary、SetBcBySurfaceAsync、体素/速度纹理 |
| **烟雾场** | 移除 | 不再支持烟雾场 |
| **Poisson** | 简化 | 固定迭代次数、去掉容差模式 |
| **工程** | 调整 | 新工程 dynamic_obstacle，集成体素化与 Vulkan |

---

## 八、适用场景建议

| 场景 | 更推荐 |
|------|--------|
| 高精度、无动态固体 | LFM（Leapfrog 多步 + RK4） |
| 动态固体交互、实时性优先 | OFM（One-Step + 动态边界） |
| 需要烟雾/密度场 | LFM |
| 需要与体素化管线集成 | OFM |

---

## 参考文献

- Sun et al., "Leapfrog Flow Maps for Real-Time Fluid Simulation", ACM TOG 2025
- Yutong Sun, "One-Step Flow Maps for Real-time Fluid Simulation with Dynamic Boundaries", Georgia Tech MSCS Thesis
