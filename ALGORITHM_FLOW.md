# LFM (Leapfrog Flow Maps) 算法详细流程

本文档详细描述了LFM流体模拟算法的完整计算流程。

## 目录
1. [算法概述](#算法概述)
2. [数据结构](#数据结构)
3. [初始化阶段](#初始化阶段)
4. [主循环流程](#主循环流程)
5. [Advance阶段详解](#advance阶段详解)
6. [Reinit阶段详解](#reinit阶段详解)
7. [关键函数说明](#关键函数说明)
8. [函数所在文件对照表](#函数所在文件对照表)

---

## 算法概述

LFM (Leapfrog Flow Maps) 是一种高效的实时流体模拟算法，核心思想是：
- 使用**Flow Maps（流映射）**来追踪流体的拉格朗日运动
- 采用**Leapfrog（蛙跳）**时间积分方案
- 使用**BFECC（Back and Forth Error Compensation and Correction）**进行误差修正
- 在MAC（Marker-And-Cell）网格上使用交错网格存储速度场

### 核心概念

1. **Flow Maps（流映射）**：
   - **后向Flow Map (ψ, T)**：记录粒子从初始位置到当前位置的轨迹
   - **前向Flow Map (φ, F)**：记录粒子从当前位置回到初始位置的轨迹
   - **T和F**：切向量，用于在Pullback操作中正确变换向量场

2. **Leapfrog方案**：
   - 每`reinit_every_`步重新初始化Flow Maps
   - 在两次reinit之间，使用中间速度场进行advection

3. **BFECC修正**：
   - 通过前向和后向advection计算误差
   - 使用误差修正来提高数值精度

---

## 数据结构

### 速度场存储（MAC网格）
- `u_x_`, `u_y_`, `u_z_`：当前速度场的三个分量（交错网格）
- `init_u_x_`, `init_u_y_`, `init_u_z_`：初始速度场（reinit时刻的速度）
- `mid_u_x_[i]`, `mid_u_y_[i]`, `mid_u_z_[i]`：中间速度场（存储reinit周期内的历史速度）
- `tmp_u_x_`, `tmp_u_y_`, `tmp_u_z_`：临时缓冲区
- `err_u_x_`, `err_u_y_`, `err_u_z_`：误差场（用于BFECC）

### Flow Maps
- **后向Flow Map**：
  - `psi_x_`, `psi_y_`, `psi_z_`：后向流映射的位置（3D向量）
  - `T_x_`, `T_y_`, `T_z_`：后向流映射的切向量（3D向量）
- **前向Flow Map**：
  - `phi_x_`, `phi_y_`, `phi_z_`：前向流映射的位置（3D向量）
  - `F_x_`, `F_y_`, `F_z_`：前向流映射的切向量（3D向量）

### 其他
- `step_`：当前步数
- `reinit_every_`：每多少步重新初始化Flow Maps
- `rk_order_`：Runge-Kutta积分阶数（2或4）

---

## 初始化阶段

### `InitLFMAsync()` 流程  
**所在文件**：声明 `src/lfm/lfm_init.h`，实现 `src/lfm/lfm_init.cu`

```cpp
void InitLFMAsync(LFM& _lfm, const LFMConfiguration& _config, cudaStream_t _stream)
```

#### 步骤1：内存分配
- 根据`tile_dim`分配所有缓冲区
- MAC网格尺寸：
  - X分量：`(tile_dim.x + 1) × tile_dim.y × tile_dim.z × 512`
  - Y分量：`tile_dim.x × (tile_dim.y + 1) × tile_dim.z × 512`
  - Z分量：`tile_dim.x × tile_dim.y × (tile_dim.z + 1) × 512`
- 中心网格：`tile_dim.x × tile_dim.y × tile_dim.z × 512`

#### 步骤2：设置模拟参数
- `rk_order_`：Runge-Kutta阶数（默认4）
- `step_ = 0`：初始化步数
- `dx_`：网格间距
- `grid_origin_`：网格原点

#### 步骤3：设置边界条件
- 设置壁面边界条件（`SetWallBcAsync`，定义于 `src/lfm/lfm_util.cu`）
- 如果使用静态固体，从SDF文件加载并设置边界（`SetBcByPhiAsync`，定义于 `src/lfm/lfm_util.cu`）
- 设置入口速度（`inlet_norm_`, `inlet_angle_`）

#### 步骤4：加载初始速度场
- 从`.npy`文件读取初始速度场（`ReadNpy`，在 data_io 中）
- 转换为tile格式（`StagConToTileAsync`，在 data_io 中）
- 存储到`init_u_x_`, `init_u_y_`, `init_u_z_`

#### 步骤5：初始化Poisson求解器
- 设置Poisson方程的系数矩阵（`SetCoefByIsBcAsync`，定义于 `src/lfm/lfm_util.cu`）
- 构建AMGPCG求解器（`BuildAsync`，在 AMGPCG 子模块中）
- 设置求解参数（最大迭代次数等）

#### 步骤6：初始化烟雾场（可选）
- 如果`num_smoke_ > 0`，加载初始烟雾场
- 存储到`smoke_[i]`和`init_smoke_[i]`

#### 步骤7：设置BFECC clamp选项
- `use_bfecc_clamp_`：是否使用BFECC clamping

---

## 主循环流程

### `PhysicsEngineUser::step()` 主循环  
**所在文件**：`proj/sim_render/physics.cu`

```cpp
void PhysicsEngineUser::step()
{
    // 1. 渲染数据准备
    GetCenteralVecAsync(u_, init_u_x_, init_u_y_, init_u_z_);  // 计算中心速度 → lfm_util.cu
    GetVorNormAsync(vor_norm_, u_, dx_);                        // 计算涡度 → lfm_util.cu
    writeToVorticity(...);                                       // 写入渲染缓冲区 → physics.cu 内联
    
    // 2. 物理模拟
    float dt = 1.0f / (frame_rate * reinit_every_);
    for (int i = 0; i < reinit_every_; i++) {
        AdvanceAsync(dt, stream);  // 执行reinit_every_次Advance → lfm.cu
    }
    ReinitAsync(dt, stream);       // 执行一次Reinit → lfm.cu
}
```

**关键点**：
- 每个渲染帧执行`reinit_every_`次`AdvanceAsync`
- 然后执行一次`ReinitAsync`
- 时间步长：`dt = 1.0f / (frame_rate * reinit_every_)`

---

## Advance阶段详解

### `AdvanceAsync(float _dt, cudaStream_t _stream)` 流程  
**所在文件**：声明 `src/lfm/lfm.h`，实现 `src/lfm/lfm.cu`

这是算法的核心推进步骤，每帧执行`reinit_every_`次。

#### 步骤1：确定时间步长和速度场源

根据`step_ % reinit_every_`的值选择不同的策略：

**情况A：`step_ % reinit_every_ == 0`（新周期开始）**
```cpp
mid_dt = 0.5f * _dt;                    // 半时间步
last_proj_u = init_u;                  // 使用初始速度场
src_u = init_u;                         // 源速度场也是初始速度场
```

**情况B：`step_ % reinit_every_ == 1`（周期第二步）**
```cpp
mid_dt = _dt;                           // 完整时间步
last_proj_u = mid_u[0];                // 使用第一步的中间速度
src_u = mid_u[0];                       // 源速度场也是mid_u[0]
```

**情况C：`step_ % reinit_every_ >= 2`（后续步骤）**
```cpp
mid_dt = 2.0f * _dt;                    // 双倍时间步（Leapfrog特性）
last_proj_u = mid_u[step_ % reinit_every_ - 1];  // 使用前一步的中间速度
src_u = mid_u[step_ % reinit_every_ - 2];         // 使用前两步的中间速度
```

#### 步骤2：Advection（平流）

使用RK2方法对速度场进行advection：

```cpp
AdvectN2XAsync(...);  // 定义于 src/lfm/lfm_util.cu
AdvectN2YAsync(...);
AdvectN2ZAsync(...);
```

**Advection原理**：
- 对于MAC网格上的每个速度分量，使用RK2积分追踪粒子轨迹
- 从当前位置反向追踪`mid_dt`时间
- 在追踪到的位置插值源速度场

#### 步骤3：设置入口边界条件

```cpp
SetInletAsync(bc_val_x_, bc_val_y_, tile_dim_, inlet_norm_, inlet_angle_);
```

设置入口处的速度边界值。（`SetInletAsync` 定义于 `src/lfm/lfm_util.cu`）

#### 步骤4：压力投影（Projection）

```cpp
ProjectAsync(_stream);  // 定义于 src/lfm/lfm.cu
```

**Projection流程**（详见`ProjectAsync`函数）：

1. **设置边界条件**：`SetBcAxisAsync` → `src/lfm/lfm_util.cu`
2. **计算散度**：`CalcDivAsync` → `src/lfm/lfm_util.cu`
   - 计算速度场的散度：`div(u) = ∂u_x/∂x + ∂u_y/∂y + ∂u_z/∂z`
3. **求解Poisson方程**：`amgpcg_.SolveAsync()`（AMGPCG 子模块）
   - 求解：`∇²p = div(u)`，得到压力场`p`
4. **应用压力梯度**：`ApplyPressureAsync` → `src/lfm/lfm_util.cu`
   - 更新速度：`u_new = u_old - ∇p`，使速度场无散

#### 步骤5：保存中间速度场

```cpp
mid_u_x_[step_ % reinit_every_].swap(tmp_u_x_);
mid_u_y_[step_ % reinit_every_].swap(tmp_u_y_);
mid_u_z_[step_ % reinit_every_].swap(tmp_u_z_);
step_++;
```

将投影后的速度场保存到对应的中间缓冲区，供后续步骤使用。

---

## Reinit阶段详解

### `ReinitAsync(float _dt, cudaStream_t _stream)` 流程  
**所在文件**：声明 `src/lfm/lfm.h`，实现 `src/lfm/lfm.cu`

这是算法的关键阶段，每`reinit_every_`步执行一次，用于重新初始化Flow Maps并进行BFECC误差修正。

#### 阶段1：重置Flow Maps

```cpp
ResetForwardFlowMapAsync(_stream);   // 重置前向Flow Map → lfm.cu
ResetBackwardFlowMapAsync(_stream);  // 重置后向Flow Map → lfm.cu
```

**重置操作**：
- `psi_x/y/z`：设置为网格点的物理位置
- `T_x/y/z`：设置为单位切向量（x: (1,0,0), y: (0,1,0), z: (0,0,1)）
- `phi_x/y/z`和`F_x/y/z`：同样重置为单位映射

#### 阶段2：计算后向Flow Map（反向积分）

```cpp
for (int i = reinit_every_ - 1; i >= 0; i--) {
    RKAxisAsync(rk_order_, psi_x_, T_x_, mid_u_x_[i], mid_u_y_[i], mid_u_z_[i], dt);
    RKAxisAsync(rk_order_, psi_y_, T_y_, mid_u_x_[i], mid_u_y_[i], mid_u_z_[i], dt);
    RKAxisAsync(rk_order_, psi_z_, T_z_, mid_u_x_[i], mid_u_y_[i], mid_u_z_[i], dt);
}
```

**关键点**：
- **反向遍历**：从`reinit_every_ - 1`到`0`（时间倒流）
- **积分方向**：正向时间（`dt > 0`），但因为是反向遍历，实际效果是反向积分
- **目的**：计算从初始时刻到当前时刻的流映射

**RKAxisAsync原理**：
- 使用Runge-Kutta（RK2或RK4）积分ODE：`dψ/dt = -u(ψ)`
- 同时积分切向量：`dT/dt = -∇u · T`
- `psi`：粒子位置
- `T`：切向量（用于Pullback时正确变换向量）

**所在文件**：声明 `src/lfm/lfm_util.h`，实现 `src/lfm/lfm_util.cu`

#### 阶段3：计算前向Flow Map（正向积分）

```cpp
for (int i = 0; i < reinit_every_; i++) {
    RKAxisAsync(rk_order_, phi_x_, F_x_, mid_u_x_[i], mid_u_y_[i], mid_u_z_[i], -dt);
    RKAxisAsync(rk_order_, phi_y_, F_y_, mid_u_x_[i], mid_u_y_[i], mid_u_z_[i], -dt);
    RKAxisAsync(rk_order_, phi_z_, F_z_, mid_u_x_[i], mid_u_y_[i], mid_u_z_[i], -dt);
}
```

**关键点**：
- **正向遍历**：从`0`到`reinit_every_ - 1`
- **积分方向**：负时间（`-dt`），实际效果是正向积分
- **目的**：计算从当前时刻回到初始时刻的流映射

#### 阶段4：使用后向Flow Map进行Pullback（第一次）

```cpp
PullbackAxisAsync(u_x_, init_u_x_, init_u_y_, init_u_z_, psi_x_, T_x_);
PullbackAxisAsync(u_y_, init_u_x_, init_u_y_, init_u_z_, psi_y_, T_y_);
PullbackAxisAsync(u_z_, init_u_x_, init_u_y_, init_u_z_, psi_z_, T_z_);
```

**Pullback操作**：
- 使用后向Flow Map `psi`和`T`，将初始速度场`init_u`变换到当前时刻
- 对于每个网格点`x`：
  1. 找到`psi(x)`（该点在初始时刻的位置）
  2. 在`psi(x)`处插值初始速度场：`u_init = Interp(init_u, psi(x))`
  3. 使用切向量`T`变换：`u(x) = T · u_init`

**数学原理**：
- Pullback操作实现了拉格朗日advection：`u(x,t) = T(x,t) · u(ψ(x,t), 0)`
- `T`是雅可比矩阵的列向量，用于正确变换向量场

#### 阶段5：使用前向Flow Map计算误差（第二次Pullback）

```cpp
PullbackAxisAsync(err_u_x_, u_x_, u_y_, u_z_, phi_x_, F_x_);
PullbackAxisAsync(err_u_y_, u_x_, u_y_, u_z_, phi_y_, F_y_);
PullbackAxisAsync(err_u_z_, u_x_, u_y_, u_z_, phi_z_, F_z_);
```

**目的**：
- 将当前速度场`u`通过前向Flow Map `phi`变换回初始时刻
- 得到`u(phi(x), t)`，即"如果从当前时刻回到初始时刻，速度场会是什么"

#### 阶段6：计算误差

```cpp
AddFieldsAsync(err_u_x_, err_u_x_, init_u_x_, -1.0f);  // err = u(phi) - init_u
AddFieldsAsync(err_u_y_, err_u_y_, init_u_y_, -1.0f);
AddFieldsAsync(err_u_z_, err_u_z_, init_u_z_, -1.0f);
```

**误差定义**：
- `err = u(phi(x), t) - init_u(x)`
- 如果advection完全精确，这个误差应该为0
- 误差反映了数值积分和插值的累积误差

#### 阶段7：将误差Pullback回当前时刻（第三次Pullback）

```cpp
PullbackAxisAsync(init_u_x_, err_u_x_, err_u_y_, err_u_z_, psi_x_, T_x_);
PullbackAxisAsync(init_u_y_, err_u_x_, err_u_y_, err_u_z_, psi_y_, T_y_);
PullbackAxisAsync(init_u_z_, err_u_x_, err_u_y_, err_u_z_, psi_z_, T_z_);
```

**目的**：
- 将误差场通过后向Flow Map变换回当前时刻
- 得到误差在当前时刻的分布：`err_corrected = T · err(psi(x))`

#### 阶段8：BFECC修正

```cpp
AddFieldsAsync(tmp_u_x_, u_x_, init_u_x_, -0.5f);  // u_corrected = u - 0.5 * err_corrected
AddFieldsAsync(tmp_u_y_, u_y_, init_u_y_, -0.5f);
AddFieldsAsync(tmp_u_z_, u_z_, init_u_z_, -0.5f);
```

**BFECC公式**：
- `u_corrected = u - 0.5 * err_corrected`
- 这是BFECC（Back and Forth Error Compensation and Correction）的核心公式
- 通过减去一半的误差来修正速度场

#### 阶段9：BFECC Clamping（可选）

```cpp
if (use_bfecc_clamp_) {
    BfeccClampAsync(tmp_u_x_, u_x_);
    BfeccClampAsync(tmp_u_y_, u_y_);
    BfeccClampAsync(tmp_u_z_, u_z_);
}
```

**目的**：
- 防止BFECC修正导致的值超出合理范围
- 将修正后的值限制在原始值的范围内

#### 阶段10：最终投影

```cpp
ProjectAsync(_stream);
```

确保修正后的速度场仍然无散。

#### 阶段11：更新初始速度场

```cpp
init_u_x_.swap(tmp_u_x_);
init_u_y_.swap(tmp_u_y_);
init_u_z_.swap(tmp_u_z_);
```

将修正后的速度场作为新的初始速度场，供下一个周期使用。

#### 阶段12：更新烟雾场（如果存在）

```cpp
if (num_smoke_ > 0) {
    GetCentralPsiAsync(psi_c_, psi_x_, psi_y_, psi_z_);  // 计算中心位置的psi
    GetCentralPsiAsync(phi_c_, phi_x_, phi_y_, phi_z_);  // 计算中心位置的phi
    
    for (int i = 0; i < num_smoke_; i++) {
        PullbackCenterAsync(smoke_[i], init_smoke_[i], psi_c_);      // 第一次Pullback
        PullbackCenterAsync(err_smoke_, smoke_[i], phi_c_);         // 第二次Pullback
        AddFieldsAsync(err_smoke_, err_smoke_, init_smoke_[i], -1.0f);  // 计算误差
        PullbackCenterAsync(tmp_smoke_, err_smoke_, psi_c_);         // 第三次Pullback
        AddFieldsAsync(smoke_[i], smoke_[i], tmp_smoke_, -0.5f);     // BFECC修正
        init_smoke_[i] = smoke_[i];                                 // 更新初始烟雾场
    }
}
```

烟雾场的更新流程与速度场类似，但使用中心位置的Flow Map（因为烟雾场存储在中心网格上）。

---

## 关键函数说明

### 1. `RKAxisAsync()` - Runge-Kutta积分计算Flow Maps

**功能**：使用RK2或RK4方法积分ODE来计算Flow Maps

**输入**：
- `rk_order`：积分阶数（2或4）
- `psi_axis`, `T_axis`：Flow Map的位置和切向量（输入输出）
- `u_x`, `u_y`, `u_z`：速度场
- `dt`：时间步长（可为正或负）

**算法**（以RK2为例）：
```
1. 当前位置：pos = psi[idx]
2. 当前切向量：T1 = T[idx]
3. 计算速度：u1 = InterpMacN2(u, pos)
4. 计算速度梯度：grad = ∇u(pos)
5. 计算切向量变化率：dT/dt = grad · T1
6. 中间位置：pos_mid = pos - 0.5*dt*u1
7. 中间切向量：T2 = T1 - 0.5*dt*dT/dt
8. 中间速度：u2 = InterpMacN2(u, pos_mid)
9. 最终位置：psi[idx] = pos - dt*u2
10. 最终切向量：T[idx] = T1 - dt*(grad · T2)
```

**关键点**：
- 使用MAC网格上的B样条插值（N2）来插值速度场
- 同时积分位置和切向量
- 切向量用于在Pullback时正确变换向量场

### 2. `PullbackAxisAsync()` - 使用Flow Map进行Pullback操作

**功能**：使用Flow Map将源速度场变换到目标网格

**输入**：
- `dst_axis`：目标速度分量（输出）
- `src_x`, `src_y`, `src_z`：源速度场的三个分量
- `psi_axis`, `T_axis`：Flow Map的位置和切向量

**算法**：
```
对于每个网格点x：
1. 获取Flow Map位置：pos = psi_axis[x]
2. 在pos处插值源速度场：u_src = InterpMacN2(src, pos)
3. 获取切向量：T = T_axis[x]
4. 变换速度：dst_axis[x] = T · u_src（点积）
```

**数学原理**：
- Pullback操作实现了拉格朗日advection
- `T`是雅可比矩阵`∂ψ/∂x`的列向量
- 对于向量场，需要使用切向量来正确变换方向

**所在文件**：声明 `src/lfm/lfm_util.h`，实现 `src/lfm/lfm_util.cu`

### 3. `AdvectN2X/Y/ZAsync()` - MAC网格上的Advection  
**所在文件**：声明 `src/lfm/lfm_util.h`，实现 `src/lfm/lfm_util.cu`

**功能**：使用RK2方法对MAC网格上的速度分量进行advection

**输入**：
- `dst`：advection后的速度分量（输出）
- `src`：源速度分量
- `u_x`, `u_y`, `u_z`：用于advection的速度场
- `dt`：时间步长

**算法**（以X分量为例）：
```
对于每个X-face网格点x：
1. 当前位置：pos1 = (x, y+0.5, z+0.5) * dx
2. 插值速度：u1 = InterpMacN2(u, pos1)
3. 中间位置：pos2 = pos1 - 0.5*dt*u1
4. 插值中间速度：u2 = InterpMacN2(u, pos2)
5. 最终位置：pos_final = pos1 - dt*u2
6. 在pos_final处插值源速度场：dst[x] = InterpN2X(src, pos_final)
```

**关键点**：
- 使用RK2方法追踪粒子轨迹
- 反向追踪（从当前位置向后追踪）
- 使用B样条插值（N2）来插值速度场和源场

### 4. `ProjectAsync()` - 压力投影  
**所在文件**：声明 `src/lfm/lfm.h`，实现 `src/lfm/lfm.cu`

**功能**：使速度场无散（divergence-free）

**步骤**：
1. **设置边界条件**：`SetBcAxisAsync()`
2. **计算散度**：`CalcDivAsync()` → `b = div(u)`
3. **求解Poisson方程**：`amgpcg_.SolveAsync()` → `∇²p = b`
4. **应用压力梯度**：`ApplyPressureAsync()` → `u_new = u_old - ∇p`

**数学原理**：
- Helmholtz分解：`u = u_divfree + ∇φ`
- 投影操作：`P(u) = u - ∇(∇²)⁻¹div(u)`
- 结果：`div(P(u)) = 0`

### 5. `CalcDivAsync()` - 计算散度  
**所在文件**：声明 `src/lfm/lfm_util.h`，实现 `src/lfm/lfm_util.cu`

**功能**：计算速度场的散度

**算法**：
```
对于每个中心网格点(i,j,k)：
div = (u_x[i+1,j,k] - u_x[i,j,k]) / dx
    + (u_y[i,j+1,k] - u_y[i,j,k]) / dy
    + (u_z[i,j,k+1] - u_z[i,j,k]) / dz
```

### 6. `ApplyPressureAsync()` - 应用压力梯度  
**所在文件**：声明 `src/lfm/lfm_util.h`，实现 `src/lfm/lfm_util.cu`

**功能**：通过减去压力梯度来更新速度场

**算法**：
```
对于X-face：u_x[i] += (p[i-1] - p[i]) / dx
对于Y-face：u_y[j] += (p[j-1] - p[j]) / dy
对于Z-face：u_z[k] += (p[k-1] - p[k]) / dz
```

---

## 函数所在文件对照表

文档中提到的函数及其声明/定义所在文件如下。

| 函数名 | 声明 | 定义/实现 |
|--------|------|-----------|
| `InitLFMAsync` | `src/lfm/lfm_init.h` | `src/lfm/lfm_init.cu` |
| `AdvanceAsync` | `src/lfm/lfm.h` | `src/lfm/lfm.cu` |
| `ReinitAsync` | `src/lfm/lfm.h` | `src/lfm/lfm.cu` |
| `ResetForwardFlowMapAsync` | `src/lfm/lfm.h` | `src/lfm/lfm.cu` |
| `ResetBackwardFlowMapAsync` | `src/lfm/lfm.h` | `src/lfm/lfm.cu` |
| `ProjectAsync` | `src/lfm/lfm.h` | `src/lfm/lfm.cu` |
| `RKAxisAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `PullbackAxisAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `PullbackCenterAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `AdvectN2XAsync` / `AdvectN2YAsync` / `AdvectN2ZAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `SetInletAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `SetBcAxisAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `CalcDivAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `ApplyPressureAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `SetWallBcAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `SetBcByPhiAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `SetCoefByIsBcAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `AddFieldsAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `GetCentralPsiAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `BfeccClampAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `GetCenteralVecAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `GetVorNormAsync` | `src/lfm/lfm_util.h` | `src/lfm/lfm_util.cu` |
| `PhysicsEngineUser::step` | `proj/sim_render/physics.h` | `proj/sim_render/physics.cu` |
| `writeToVorticity`（CUDA kernel） | — | `proj/sim_render/physics.cu` |

**说明**：
- `ResetToIdentityXASync` / `ResetToIdentityYASync` / `ResetToIdentityZASync`：声明与实现均在 `src/lfm/lfm_util.h` / `src/lfm/lfm_util.cu`（在 `ResetForwardFlowMapAsync` / `ResetBackwardFlowMapAsync` 内被调用）。
- `ReadNpy`、`ConToTileAsync`、`StagConToTileAsync`、`DevToDevCpyAsync`：在 `lfm_init.cu` 等处使用，定义在项目所依赖的 data_io / 工具模块中。
- `amgpcg_.BuildAsync`、`amgpcg_.SolveAsync`：属于 AMGPCG 子模块（见 README 中的 submodule 说明）。

---

## 算法流程图总结

```
初始化
  ↓
主循环开始
  ↓
┌─────────────────────────────────┐
│ 渲染数据准备（可选）              │
│ - 计算中心速度                    │
│ - 计算涡度                        │
└─────────────────────────────────┘
  ↓
┌─────────────────────────────────┐
│ Advance阶段（执行reinit_every_次）│
│                                  │
│ 1. 选择时间步长和速度场源         │
│ 2. Advection（RK2）              │
│ 3. 设置入口边界条件               │
│ 4. 压力投影                       │
│ 5. 保存中间速度场                 │
└─────────────────────────────────┘
  ↓
┌─────────────────────────────────┐
│ Reinit阶段（每reinit_every_步一次）│
│                                  │
│ 1. 重置Flow Maps                 │
│ 2. 计算后向Flow Map（反向积分）   │
│ 3. 计算前向Flow Map（正向积分）   │
│ 4. Pullback（使用后向Flow Map）   │
│ 5. Pullback（使用前向Flow Map）   │
│ 6. 计算误差                       │
│ 7. Pullback误差                  │
│ 8. BFECC修正                     │
│ 9. BFECC Clamping（可选）        │
│ 10. 最终投影                     │
│ 11. 更新初始速度场               │
│ 12. 更新烟雾场（可选）           │
└─────────────────────────────────┘
  ↓
继续主循环
```

---

## 关键参数说明

- **`reinit_every_`**：每多少步重新初始化Flow Maps
  - 值越大，计算效率越高，但精度可能降低
  - 典型值：3-5

- **`rk_order_`**：Runge-Kutta积分阶数
  - 2：RK2，速度快但精度较低
  - 4：RK4，精度高但速度较慢
  - 典型值：4

- **`use_bfecc_clamp_`**：是否使用BFECC clamping
  - true：防止修正后的值超出范围
  - false：不使用clamping，可能更精确但可能不稳定

---

## 性能优化要点

1. **Tile-based存储**：使用tile结构（8×8×8 voxels per tile）提高内存访问效率
2. **CUDA异步执行**：所有操作使用异步CUDA流，隐藏内存传输延迟
3. **AMGPCG求解器**：使用代数多重网格预条件共轭梯度法快速求解Poisson方程
4. **B样条插值**：使用N2 B样条插值，平衡精度和性能

---

## 参考文献

- Sun et al., "Leapfrog Flow Maps for Real-Time Fluid Simulation", ACM TOG 2025
- BFECC: Back and Forth Error Compensation and Correction
- MAC Grid: Marker-And-Cell staggered grid
- Flow Maps: Lagrangian flow map representation
