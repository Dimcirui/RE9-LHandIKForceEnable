-- r_wep_pose_explore.lua  v3
-- 路径: cp_A100 -> Transform -> getJointByName("R_Wep")
-- 写入钩子: re.on_pre_application_entry("PrepareRendering")
--   → 在动画系统更新之后、渲染之前写入，避免被动画覆盖

local TARGET_GO    = "cp_A100"
local TARGET_JOINT = "R_Wep"

local state = {
    log        = {},
    transform  = nil,   -- cp_A100 的 Transform
    rwep_joint = nil,   -- via.Joint

    -- 读取到的值
    cur_local_pos = nil,
    cur_world_pos = nil,
    cur_local_rot = nil,

    -- 用户偏移（LocalPosition 附加量）
    off_x = 0.0,
    off_y = 0.0,
    off_z = 0.0,

    -- 基准位置（按下 Capture 时记录）
    base_pos = nil,

    -- 持续写入开关
    continuous = false,

    -- 关节枚举缓存
    all_joints      = nil,
    joint_list_text = nil,

    -- 统计
    write_count = 0,
}

------------------------------------------------------
-- 日志
------------------------------------------------------
local function log_add(msg)
    table.insert(state.log, msg)
    if #state.log > 60 then table.remove(state.log, 1) end
    log.info("[RWepV3] " .. msg)
end

------------------------------------------------------
-- 获取 scene
------------------------------------------------------
local function get_scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    local scene = nil
    pcall(function()
        scene = sdk.call_native_func(sm,
            sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    end)
    return scene
end

------------------------------------------------------
-- 找目标 GO 和 Transform
------------------------------------------------------
local function find_transform()
    local scene = get_scene()
    if not scene then return nil end
    local go = nil
    pcall(function() go = scene:call("findGameObject(System.String)", TARGET_GO) end)
    if not go then return nil end
    local t = nil
    pcall(function() t = go:call("get_Transform") end)
    return t
end

------------------------------------------------------
-- 验证 Joint 仍有效
------------------------------------------------------
local function joint_valid(j)
    if not j then return false end
    local ok = pcall(function() j:call("get_Position") end)
    return ok
end

------------------------------------------------------
-- 查找 R_Wep Joint
------------------------------------------------------
local function find_rwep_joint(transform)
    if not transform then return nil end
    local j = nil
    pcall(function() j = transform:call("getJointByName", TARGET_JOINT) end)
    return j
end

------------------------------------------------------
-- 枚举所有关节名（调试用）
------------------------------------------------------
local function enumerate_joints(transform)
    state.all_joints = {}
    state.joint_list_text = nil
    if not transform then log_add("No transform for enum"); return end

    local count = nil
    pcall(function() count = transform:call("getJointCount") end)
    if count then
        log_add(string.format("Joint count: %d", count))
        local names = {}
        for i = 0, count - 1 do
            local j = nil
            pcall(function() j = transform:call("getJointAt", i) end)
            if j then
                local n = nil
                pcall(function() n = j:call("get_Name") end)
                if n then
                    table.insert(state.all_joints, { name = n, joint = j })
                    table.insert(names, n)
                end
            end
        end
        state.joint_list_text = table.concat(names, ", ")
        log_add("Joints: " .. (state.joint_list_text or "(none)"))
    else
        log_add("getJointCount not available")
    end
end

------------------------------------------------------
-- 主探索
------------------------------------------------------
local function do_explore()
    state.log = {}
    state.rwep_joint = nil
    state.transform  = nil
    state.cur_local_pos = nil
    state.all_joints = nil
    state.write_count = 0
    log_add("=== Explore (Joint path) ===")

    local t = find_transform()
    if not t then
        log_add("Transform not found for " .. TARGET_GO)
        return
    end
    state.transform = t
    log_add("Transform found: " .. TARGET_GO)

    local j = find_rwep_joint(t)
    if j then
        state.rwep_joint = j
        log_add("Joint '" .. TARGET_JOINT .. "': FOUND")
        local pos = nil
        pcall(function() pos = j:call("get_LocalPosition") end)
        if pos then
            state.cur_local_pos = pos
            log_add(string.format("  LocalPos: (%.4f, %.4f, %.4f)", pos.x, pos.y, pos.z))
        else
            log_add("  LocalPos: <read failed>")
        end
        local wpos = nil
        pcall(function() wpos = j:call("get_Position") end)
        if wpos then
            state.cur_world_pos = wpos
            log_add(string.format("  WorldPos: (%.4f, %.4f, %.4f)", wpos.x, wpos.y, wpos.z))
        end
        local rot = nil
        pcall(function() rot = j:call("get_LocalEulerAngle") end)
        if rot then
            state.cur_local_rot = rot
            log_add(string.format("  LocalEuler: (%.2f, %.2f, %.2f)", rot.x, rot.y, rot.z))
        end
    else
        log_add("Joint '" .. TARGET_JOINT .. "': NOT FOUND — enumerating all joints...")
        enumerate_joints(t)
    end
    log_add("=== Done ===")
end

------------------------------------------------------
-- 写入 LocalPosition（单次，用于 Apply Once 按钮）
------------------------------------------------------
local function write_pos(x, y, z)
    if not joint_valid(state.rwep_joint) then
        state.rwep_joint = nil
        log_add("Joint lost, retrying...")
        if state.transform then
            state.rwep_joint = find_rwep_joint(state.transform)
        end
        if not state.rwep_joint then return false end
    end
    local ok = pcall(function()
        state.rwep_joint:call("set_LocalPosition", Vector3f.new(x, y, z))
    end)
    return ok
end

------------------------------------------------------
-- on_frame: 只做缓存刷新 + 读取
-- 不在这里写！re.on_frame 在动画系统之前运行，写了会被覆盖
------------------------------------------------------
re.on_frame(function()
    -- 验证 transform 缓存
    if state.transform then
        local ok = pcall(function() state.transform:call("get_GameObject") end)
        if not ok then
            state.transform = nil
            state.rwep_joint = nil
        end
    end

    -- 刷新 joint 缓存
    if not joint_valid(state.rwep_joint) then
        state.rwep_joint = nil
        if not state.transform then
            state.transform = find_transform()
        end
        if state.transform then
            state.rwep_joint = find_rwep_joint(state.transform)
        end
    end

    -- 读取当前值（用于 UI 显示）
    if state.rwep_joint then
        pcall(function() state.cur_local_pos = state.rwep_joint:call("get_LocalPosition") end)
        pcall(function() state.cur_world_pos = state.rwep_joint:call("get_Position") end)
        pcall(function() state.cur_local_rot = state.rwep_joint:call("get_LocalEulerAngle") end)
    end
end)

------------------------------------------------------
-- PrepareRendering 钩子：动画运行完毕后、渲染前写入
-- 这是让 set_LocalPosition 能持续生效的关键！
------------------------------------------------------
re.on_pre_application_entry("PrepareRendering", function()
    if not state.continuous then return end
    if not state.base_pos then return end
    if not joint_valid(state.rwep_joint) then return end
    local ok = pcall(function()
        state.rwep_joint:call("set_LocalPosition", Vector3f.new(
            state.base_pos.x + state.off_x,
            state.base_pos.y + state.off_y,
            state.base_pos.z + state.off_z
        ))
    end)
    if ok then state.write_count = state.write_count + 1 end
end)

------------------------------------------------------
-- UI
------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.collapsing_header("R_Wep Joint Fix v3") then return end

    if imgui.button("Find R_Wep Joint") then
        pcall(do_explore)
    end
    imgui.same_line()
    if imgui.button("Enumerate All Joints") then
        if not state.transform then state.transform = find_transform() end
        pcall(enumerate_joints, state.transform)
    end

    imgui.separator()

    local joint_ok = joint_valid(state.rwep_joint)
    imgui.text("R_Wep joint: " .. (joint_ok and "FOUND" or "NOT FOUND"))

    if state.cur_local_pos then
        imgui.text(string.format("LocalPos  : (%.4f, %.4f, %.4f)",
            state.cur_local_pos.x, state.cur_local_pos.y, state.cur_local_pos.z))
    end
    if state.cur_world_pos then
        imgui.text(string.format("WorldPos  : (%.4f, %.4f, %.4f)",
            state.cur_world_pos.x, state.cur_world_pos.y, state.cur_world_pos.z))
    end
    if state.cur_local_rot then
        imgui.text(string.format("LocalEuler: (%.2f, %.2f, %.2f)",
            state.cur_local_rot.x, state.cur_local_rot.y, state.cur_local_rot.z))
    end
    imgui.text(string.format("Write count (PrepareRendering): %d", state.write_count))

    imgui.separator()
    imgui.text("Offset (added to captured base):")

    if imgui.button("Capture Base Position") then
        if state.cur_local_pos then
            state.base_pos = Vector3f.new(
                state.cur_local_pos.x,
                state.cur_local_pos.y,
                state.cur_local_pos.z)
            log_add(string.format("Base captured: (%.4f, %.4f, %.4f)",
                state.base_pos.x, state.base_pos.y, state.base_pos.z))
        else
            log_add("No LocalPos to capture")
        end
    end
    imgui.same_line()
    if state.base_pos then
        imgui.text(string.format("Base: (%.4f, %.4f, %.4f)",
            state.base_pos.x, state.base_pos.y, state.base_pos.z))
    else
        imgui.text("Base: (not captured)")
    end

    local cx, vx = imgui.drag_float("Offset X", state.off_x, 0.001, -1.0, 1.0, "%.4f")
    if cx then state.off_x = vx end
    local cy, vy = imgui.drag_float("Offset Y", state.off_y, 0.001, -1.0, 1.0, "%.4f")
    if cy then state.off_y = vy end
    local cz, vz = imgui.drag_float("Offset Z", state.off_z, 0.001, -1.0, 1.0, "%.4f")
    if cz then state.off_z = vz end

    local ch_cont, new_cont = imgui.checkbox("Continuous Write (PrepareRendering)", state.continuous)
    if ch_cont then
        state.continuous = new_cont
        state.write_count = 0
        log_add("Continuous write: " .. tostring(new_cont))
    end

    if imgui.button("Apply Once") then
        local tx = state.base_pos and (state.base_pos.x + state.off_x) or state.off_x
        local ty = state.base_pos and (state.base_pos.y + state.off_y) or state.off_y
        local tz = state.base_pos and (state.base_pos.z + state.off_z) or state.off_z
        local ok = write_pos(tx, ty, tz)
        log_add("Apply once: " .. tostring(ok))
    end
    imgui.same_line()
    if imgui.button("Reset to Base") then
        if state.base_pos then
            write_pos(state.base_pos.x, state.base_pos.y, state.base_pos.z)
        else
            write_pos(0, 0, 0)
        end
        state.off_x, state.off_y, state.off_z = 0.0, 0.0, 0.0
    end

    if state.joint_list_text then
        imgui.separator()
        imgui.text("All joints:")
        imgui.text_wrapped(state.joint_list_text)
    end

    imgui.separator()
    imgui.text("Log:")
    for i = math.max(1, #state.log - 25), #state.log do
        imgui.text("  " .. (state.log[i] or ""))
    end
end)

log.info("[RWepV3] Loaded.")
