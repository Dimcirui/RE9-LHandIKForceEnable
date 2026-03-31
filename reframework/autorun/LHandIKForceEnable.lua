-- LHandIKForceEnable.lua  v2.3
-- Fix Hand offset issue after skeleton modification in RE9
--      by forcing keep AnimLHandAdjustIK's LocalEnable=1, LocalDisable=0
-- Support characters: cp_A100 (Grace), cp_A000 (Leon)
--
-- Detection: Layer-based + distance-based for conflicting animation groups
--
-- Per-character config via JSON:
--   reframework/data/LHandIKFix/hand_ik_fix_<n>.json
--   {
--       "char_enabled": true,
--       "distance_threshold": 0.07,
--       "distance_interval": 0.5,
--       "distance_sustain": false,
--       "conditions": [ ... ],
--       "kill_conditions": [ ... ]
--   }
--
--   conditions: array of groups (OR). Each group:
--     { "checks": [...], "distance_check": true/false }
--     checks within a group = AND.
--     distance_check = use distance verification for this group (Grace conflict groups).
--   kill_conditions: array of groups (OR of AND). Immediate disable, highest priority.
--   distance_sustain: when true, if IK is already ON but no condition matches,
--     use distance check to decide whether to maintain IK (Leon's mode).

local CONFIG_DIR = "LHandIKFix/"
local OFFSET_ENABLE = 16
local OFFSET_DISABLE = 24

local cfg = {
    enabled = true,
    debug = false,           -- Debug mode toggle
    layer_interval = 0.05,   -- animation layer / kill check interval (seconds)
    -- distance check rate is controlled per-character via distance_interval
}

------------------------------------------------------
-- Character definitions
------------------------------------------------------
local characters = {
    {
        name = "Grace",
        go_name = "cp_A100",
        default_char_enabled = true,
        default_distance_threshold = 0.1,
        default_distance_interval = 0.1,
        default_distance_sustain = false,  -- Grace: Disable IK when no condition matches
        default_conditions = {
            -- 优先判断靠前的条件，因此距离检测组建议放在后面
            -- Priority is given to conditions checked first, so distance detection groups should be placed last
            {
                -- 瞄准 (L0.bank=10, L4=10/5011)，格蕾丝没有长枪，所以可以使用距离检测
                -- Aiming (L0.bank=10, L4=10/5011), Grace doesn't have long firearms so can use distance detection
                checks = {
                    { layer = 4, bank = 10, mot = 5011 },
                    { layer = 0, bank = 10 },
                    { layer = 3, bank = 100, _invert = true },
                },
                distance_check = true,
                -- distance_grace = 0.3,
            },
            {
                -- 持续瞄准 (L7=100/6001)
                -- Continuous aiming (L7=100/6001)
                checks = {
                    { layer = 4, bank = 10, mot = 5011 },
                    { layer = 7, bank = 100, mot = 6001 },
                },
            },
            {
                -- 移动时换枪 (L2.bank=2100)，靠距离检测覆盖双手握持瞬间
                checks = {
                    { layer = 2, bank = 2100 },
                },
                distance_check = true,
            },
            {
                -- 待机过渡/切枪过渡/取消瞄准过渡/闲置检视动画等 (L3.bank=100)
                -- Transition frames/Switch weapon frames/Cancel aiming frames/Idle inspection animation frames (L3.bank=100)
                checks = {
                    { layer = 3, bank = 100 },
                    { layer = 3, mot = "invalid", _invert = true },
                    -- { layer = 3, bank = 100, mot = 161, _invert = true},
                    { layer = 3, bank = 100, mot = 1611, _invert = true },
                    { layer = 3, bank = 100, mot = 1301, _invert = true },
                    { layer = 3, bank = 100, mot = 1311, _invert = true },
                    { layer = 3, bank = 100, mot = 1312, _invert = true}, --  3/12/12:40 
                    { layer = 3, bank = 100, mot = 1313, _invert = true}, --  3/12/12:40 安全室内单手拿枪收枪
                    { layer = 2, bank = 2100, _invert = true },  -- 排除移动时换枪
                },
            },
            {
                -- 非瞄准 + L4=10/5011 (待机/检视/过渡等) — 距离区分
                -- Non-aiming + L4=10/5011 (idle/inspection/transition, etc.) — distance-based
                checks = {
                    { layer = 4, bank = 10, mot = 5011 },
                    { layer = 0, bank = 10, _invert = true },
                    { layer = 7, bank = 100, _invert = true },
                },
                distance_check = true,
            },
            {
                -- 冲突组: 持枪/非持枪通用，靠距离检测区分
                -- Conflict group: General holding/non-holding, distinguished by distance detection
                checks = {
                    { layer = 3, bank = 10, mot = 5000 },
                    { layer = 4, bank = 100, mot = 6000 },
                },
                distance_check = true,
                -- distance_grace = 0.3,
            },
            -- 一些不容易归类的闲置动作
            -- Some idle animations that are difficult to classify
            {
                -- 待机动作1
                checks = {
                    { layer = 3, bank = 50, mot = 929 },
                },
            },
            {
                -- 待机动作2
                checks = {
                    { layer = 3, bank = 0, mot = 7000 },
                },
            },
            {
                -- 待机动作3
                checks = {
                    { layer = 3, bank = 50, mot = 927 },
                },
            },
            {
                -- 待机动作4
                checks = {
                    { layer = 3, bank = 0, mot = 7003 },
                },
            },
            {
                -- 待机动作5
                checks = {
                    { layer = 3, bank = 0, mot = 7002 },    -- 3/14/6:29
                },
            },
        },
        default_kill_conditions = {
            { { layer = 5, bank = 0, _invert = true } },  -- 手电筒 flashlight
            { { layer = 5, mot = 6102 } },                 -- 治疗针/切武器 syringe/switch weapon
            { { layer = 3, bank = 0, mot = "invalid" } },  -- 过场动画 cutscene
            { { layer = 3, bank = 0, mot = 6201 } },        -- 手持背包 backpack
            { { layer = 3, bank = 0, mot = 6200 } },        -- 手持背包 backpack
        },
        -- Runtime
        char_enabled = true,
        distance_threshold = 0.1,
        distance_interval = 0.1,
        distance_sustain = false,
        conditions = nil, kill_conditions = nil,
        status = "Waiting...", fix_count = 0, ik_forced = false, active_condition_str = "None",
        config_source = "default",
        _transform = nil, _joints = {}, _dist_cache = {}, _go_ref = nil,
        _ik_item = nil, _layer_cache = {}, _layer_count = 0
    },
    {
        name = "Leon",
        go_name = "cp_A000",
        default_char_enabled = true,
        default_distance_threshold = 0.1,
        default_distance_interval = 0.1,
        default_distance_sustain = true,   -- Leon: Use distance detection to maintain IK
        default_conditions = {
            {
                -- 手枪持握状态 (L3.bank=10: 包含站立/走/跑/瞄准及过渡帧)
                -- Gun holding (L3.bank=10: covers idle/walk/run/aim and transition frames)
                -- 排除非持枪状态 (L3.bank=10, mot=5000)
                -- Exclude non-gun holding state (L3.bank=10, mot=5000)
                -- 排除手枪/马格南（距离阈值接近0，由 weapon_distance_thresholds 控制）
                checks = {
                    { layer = 3, bank = 10 },
                    -- { layer = 0, bank = 10, mot = 22, _invert = true },
                    -- { layer = 4, bank = 10, mot = 5011, _invert = true },
                },
                weapons = { "Pistol", "Magnum" },
            },
            {
                -- 手枪持握状态 (L3.bank=10: 包含站立/走/跑/瞄准及过渡帧)
                -- Gun holding (L3.bank=10: covers idle/walk/run/aim and transition frames)
                -- 排除非持枪状态 (L3.bank=10, mot=5000)
                -- Exclude non-gun holding state (L3.bank=10, mot=5000)
                -- 排除手枪/马格南（距离阈值接近0，由 weapon_distance_thresholds 控制）
                checks = {
                    { layer = 3, bank = 10 },
                    { layer = 3, bank = 10, mot = 5000, _invert = true },
                },
                weapons_exclude = { "Pistol", "Magnum" },
            },
            {
                -- 霰弹枪上膛、一发后；
                checks = {
                    { layer = 3, bank = 10, mot = 5000},
                    { layer = 4, bank = 10, mot = 5010},
                },
                -- weapons_exclude = { "None" },
            },
            {
                checks = {
                    { layer = 3, bank = 100 },
                    -- { layer = 3, bank = 100, mot = 1200, _invert = true},
                    -- { layer = 3, bank = 100, mot = 1201, _invert = true},
                    -- { layer = 0, bank = 6, _invert = true},
                },
                weapons = { "Pistol", "Magnum" },
            },
            {
                -- 待机过渡/切枪过渡/取消瞄准过渡/闲置检视动画等 (L3.bank=100)
                -- Transition frames/Switch weapon frames/Cancel aiming frames/Idle inspection animation frames (L3.bank=100)
                checks = {
                    { layer = 3, bank = 100 },
                    { layer = 3, bank = 100, mot = 1200, _invert = true},
                    { layer = 3, bank = 100, mot = 1201, _invert = true},
                    { layer = 3, bank = 100, mot = 1311, _invert = true},
                    { layer = 0, bank = 6, _invert = true},
                },
                weapons_exclude = { "Pistol", "Magnum" },
            },
            -- {
            --     -- 冲突组: 持枪/非持枪通用，靠距离检测区分
            --     -- Conflict group: General holding/non-holding, distinguished by distance detection
            --     checks = {
            --         { layer = 3, bank = 10, mot = 5000 },
            --         { layer = 4, bank = 100, mot = 6000 },
            --     },
            --     distance_check = true,
            -- },
            -- 一些不容易归类的闲置动作，由于它们结束时衔接持枪待机动作，所以也需要逐条完整加入
            -- Some idle animations that are difficult to classify, because they are connected to the gun holding idle animation at the end, so they also need to be added one by one
            {
                checks = {
                    { layer = 3, bank = 0, mot = 7004 },
                    { layer = 4, bank = 100, mot = 6000 },
                },
            },
            {
                checks = {
                    { layer = 3, bank = 0, mot = "invalid", _invert = true },
                    { layer = 3, bank = 0 },
                    { layer = 4, bank = 10, mot = 5011 },
                },
            },
            {
                checks = {
                    { layer = 3, bank = 50, mot = 803 },
                    { layer = 4, bank = 10, mot = 5011 },
                },
            },
        },
        default_kill_conditions = {
            { { layer = 5, bank = 0, _invert = true } },  -- 手电筒 flashlight
            { { layer = 5, mot = 6102 } },                 -- 治疗针/切武器 syringe/switch weapon
            { { layer = 3, bank = 0, mot = "invalid" } },   -- 过场动画 cutscene
            { { layer = 0, bank = 10, mot = 22} }, -- 面对敌人时冲刺 run for enemy
            { { layer = 0, bank = 6} }, -- 也许是体技？
            { { layer = 3, bank = 5} },        -- 单手动作？ open door
        },
        default_weapon_distance_thresholds = {
            Pistol  = 0.1,
            Shotgun = 0.327,
            Grenade = 0.0,
            Melee   = 0.0,
            Magnum  = 0.1,
            SMG     = 0.275,
            Sniper  = 0.327,
        },
        arm_weapon_map = {
            { prefix = "arm00", label = "Pistol"  },
            { prefix = "arm01", label = "Shotgun" },
            { prefix = "arm02", label = "Grenade" },
            { prefix = "arm03", label = "Melee"   },
            { prefix = "arm04", label = "Magnum"  },
            { prefix = "arm05", label = "SMG"     },
            { prefix = "arm06", label = "Sniper"  },
        },
        char_enabled = true,
        distance_threshold = 0.1,
        distance_interval = 0.1,
        distance_sustain = true,
        weapon_distance_thresholds = nil,  -- populated by load_char_config
        conditions = nil, kill_conditions = nil,
        status = "Waiting...", fix_count = 0, ik_forced = false, active_condition_str = "None",
        config_source = "default",
        _transform = nil, _joints = {}, _dist_cache = {}, _go_ref = nil,
        _ik_item = nil, _layer_cache = {}, _layer_count = 0,
        _arm_cache = nil, _weapon_check_time = -999, _detected_weapon = nil
    },
}

local last_layer_check = -999
local prev_enabled = true

------------------------------------------------------
-- Normalise conditions (legacy support)
------------------------------------------------------
local function normalise_conditions(raw)
    if not raw then return nil end
    local out = {}
    for _, item in ipairs(raw) do
        if item.checks then
            table.insert(out, item)
        else
            table.insert(out, { checks = item })
        end
    end
    return out
end

------------------------------------------------------
-- JSON config
------------------------------------------------------
local function load_char_config(char)
    local filename = CONFIG_DIR .. "hand_ik_fix_" .. char.name .. ".json"
    local data = json.load_file(filename)
    if data then
        if data.char_enabled ~= nil then char.char_enabled = data.char_enabled end
        if data.distance_threshold ~= nil then char.distance_threshold = data.distance_threshold end
        if data.distance_interval ~= nil then char.distance_interval = data.distance_interval end
        if data.distance_sustain ~= nil then char.distance_sustain = data.distance_sustain end
        if data.conditions ~= nil then char.conditions = normalise_conditions(data.conditions) end
        if data.kill_conditions ~= nil then char.kill_conditions = data.kill_conditions end
        if data.weapon_distance_thresholds ~= nil then
            -- 先从 defaults 建表（若还未初始化）
            if not char.weapon_distance_thresholds and char.default_weapon_distance_thresholds then
                char.weapon_distance_thresholds = {}
                for k, v in pairs(char.default_weapon_distance_thresholds) do
                    char.weapon_distance_thresholds[k] = v
                end
            end
            -- 再用 JSON 里的值覆盖
            if char.weapon_distance_thresholds then
                for k, v in pairs(data.weapon_distance_thresholds) do
                    if type(v) == "number" then
                        char.weapon_distance_thresholds[k] = v
                    end
                end
            end
        end
        char.config_source = filename
        log.info(string.format("[IK Fix] Config loaded for %s from %s", char.name, filename))
    else
        char.char_enabled = char.default_char_enabled
        char.distance_threshold = char.default_distance_threshold
        char.distance_interval = char.default_distance_interval
        char.distance_sustain = char.default_distance_sustain
        char.conditions = char.default_conditions
        char.kill_conditions = char.default_kill_conditions
        if char.default_weapon_distance_thresholds then
            char.weapon_distance_thresholds = {}
            for k, v in pairs(char.default_weapon_distance_thresholds) do
                char.weapon_distance_thresholds[k] = v
            end
        end
        char.config_source = "default"
    end
    if not char.conditions then char.conditions = char.default_conditions end
    if not char.kill_conditions then char.kill_conditions = char.default_kill_conditions end
    if not char.weapon_distance_thresholds and char.default_weapon_distance_thresholds then
        char.weapon_distance_thresholds = {}
        for k, v in pairs(char.default_weapon_distance_thresholds) do
            char.weapon_distance_thresholds[k] = v
        end
    end
end

local function save_char_config(char)
    local filename = CONFIG_DIR .. "hand_ik_fix_" .. char.name .. ".json"
    json.dump_file(filename, {
        char_enabled = char.char_enabled,
        distance_threshold = char.distance_threshold,
        distance_interval = char.distance_interval,
        distance_sustain = char.distance_sustain,
        weapon_distance_thresholds = char.weapon_distance_thresholds,
        conditions = char.conditions,
        kill_conditions = char.kill_conditions,
    })
    char.config_source = filename
end

for _, char in ipairs(characters) do
    load_char_config(char)
end

------------------------------------------------------
-- Core: IK item finder
------------------------------------------------------
local function find_ik_item(char, go)
    if char._ik_item then
        -- Verify validity of cached managed object via quick access
        local ok = pcall(function() return char._ik_item:get_address() end)
        if ok then return char._ik_item end
        char._ik_item = nil
    end

    local acb = go:call("getComponent(System.Type)",
        sdk.typeof("anim.AnimationControllerBehavior"))
    if not acb then return nil end
    local ac = acb:get_type_definition():get_field("AnimationController"):get_data(acb)
    if not ac then return nil end
    local ab = ac:get_type_definition():get_field("AnimationBases"):get_data(ac)
    if not ab then return nil end
    local ok, count = pcall(ab.call, ab, "get_Count")
    if not ok or not count then return nil end
    for i = 0, count - 1 do
        local ok_i, item = pcall(ab.call, ab, "get_Item(System.Int32)", i)
        if ok_i and item then
            local ok_t, td = pcall(item.get_type_definition, item)
            if ok_t and td and td:get_full_name() == "anim.AnimLHandAdjustIK" then
                char._ik_item = item
                return item
            end
        end
    end
    return nil
end

------------------------------------------------------
-- Core: Layer data
------------------------------------------------------
local function get_layer_data(char, go)
    local motion = go:call("getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    if not motion then return nil end
    local lc = motion:call("getLayerCount")
    if not lc then return nil end
    
    local limit = math.min(lc - 1, 7)
    char._layer_count = limit
    
    for i = 0, limit do
        local layer = motion:call("getLayer", i)
        if layer then
            if not char._layer_cache[i] then char._layer_cache[i] = {} end
            char._layer_cache[i].bank = layer:call("get_MotionBankID") or -1
            char._layer_cache[i].mot = layer:call("get_MotionID") or -1
        end
    end
    return char._layer_cache
end

------------------------------------------------------
-- Core: Layer matching
------------------------------------------------------
local function match_check(ld, check)
    if not ld then return check._invert == true end
    local match = true
    if check.bank ~= nil and ld.bank ~= check.bank then match = false end
    if check.mot ~= nil then
        if check.mot == "invalid" then
            -- Special value: check if mot is invalid (>= 0x7FFFFFFF or game returns the maximum value)
            match = (ld.mot >= 2147483647)
        elseif ld.mot ~= check.mot then
            match = false
        end
    end
    if check._invert then return not match end
    return match
end

local function get_current_weapon(char)
    if WeaponPoseFix and WeaponPoseFix.active_weapon then
        local w = WeaponPoseFix.active_weapon[char.name]
        if w then return w end
    end
    return char._detected_weapon or "None"
end

local function match_condition_groups(layers, groups)
    if not layers or not groups then return false end
    for _, group in ipairs(groups) do
        local group_match = true
        for _, check in ipairs(group) do
            if not match_check(layers[check.layer], check) then
                group_match = false; break
            end
        end
        if group_match then return true end
    end
    return false
end

local function match_conditions(layers, conditions, char)
    if not layers or not conditions then return nil end
    for _, group in ipairs(conditions) do
        local checks = group.checks or group
        local group_match = true
        for _, check in ipairs(checks) do
            if not match_check(layers[check.layer], check) then
                group_match = false; break
            end
        end
        if group_match then
            -- 武器白名单过滤：weapons = {"Shotgun", ...} 只在这些武器时生效（"None" 表示无武器）
            if group.weapons then
                local weapon = char and get_current_weapon(char)
                local found = false
                for _, w in ipairs(group.weapons) do
                    if w == weapon then found = true; break end
                end
                if not found then group_match = false end
            end
            -- 武器黑名单过滤：weapons_exclude = {"Pistol", ...} 排除这些武器（"None" 表示无武器）
            if group_match and group.weapons_exclude then
                local weapon = char and get_current_weapon(char)
                for _, w in ipairs(group.weapons_exclude) do
                    if w == weapon then group_match = false; break end
                end
            end
        end
        if group_match then return group end
    end
    return nil
end

------------------------------------------------------
-- Core: Built-in weapon detection (reads DrawSelf only, no writes)
------------------------------------------------------
local WEAPON_DETECT_INTERVAL = 0.5

local function update_detected_weapon(char)
    if not char.arm_weapon_map then return end
    local now = os.clock()
    if now - char._weapon_check_time < WEAPON_DETECT_INTERVAL then return end
    char._weapon_check_time = now

    local t = char._transform
    if not t then return end

    -- Build or validate arm cache
    if not char._arm_cache then
        local arms = {}
        local ok, child = pcall(function() return t:call("get_Child") end)
        if not ok or not child then return end
        while child do
            local ok_go, cgo = pcall(function() return child:call("get_GameObject") end)
            if ok_go and cgo then
                local ok_n, n = pcall(function() return cgo:call("get_Name") end)
                if ok_n and n and n:sub(1, 3) == "arm" then
                    table.insert(arms, { name = n, go = cgo, transform = child })
                end
            end
            local ok_nx, nx = pcall(function() return child:call("get_Next") end)
            if not ok_nx or not nx then break end
            child = nx
        end
        char._arm_cache = arms
    end

    local IN_HAND_THRESHOLD = 0.011
    local detected = nil
    for _, arm in ipairs(char._arm_cache) do
        for _, rule in ipairs(char.arm_weapon_map) do
            if arm.name:sub(1, #rule.prefix) == rule.prefix then
                local draw_self = false
                local ok_ds = pcall(function() draw_self = arm.go:call("get_DrawSelf") end)
                if not ok_ds then char._arm_cache = nil; return end
                if draw_self then
                    local pos = nil
                    local ok_p = pcall(function() pos = arm.transform:call("get_LocalPosition") end)
                    if not ok_p then char._arm_cache = nil; return end
                    if pos and math.abs(pos.x) < IN_HAND_THRESHOLD
                           and math.abs(pos.y) < IN_HAND_THRESHOLD
                           and math.abs(pos.z) < IN_HAND_THRESHOLD then
                        detected = rule.label
                    end
                end
                break
            end
        end
        if detected then break end
    end
    char._detected_weapon = detected
end

------------------------------------------------------
-- Core: Per-weapon distance threshold
------------------------------------------------------
local function get_active_threshold(char)
    if char.weapon_distance_thresholds then
        local weapon = (WeaponPoseFix and WeaponPoseFix.active_weapon and WeaponPoseFix.active_weapon[char.name])
                    or char._detected_weapon
                    or char._last_weapon
        if weapon and char.weapon_distance_thresholds[weapon] ~= nil then
            return char.weapon_distance_thresholds[weapon]
        end
    end
    return char.distance_threshold
end

------------------------------------------------------
-- Core: Distance measurement (cached)
------------------------------------------------------
local function ensure_transform(char, go)
    if char._go_ref and char._go_ref ~= go then
        char._transform = nil; char._joints = {}; char._dist_cache = {}; char._ik_item = nil
        char._arm_cache = nil; char._detected_weapon = nil
    end
    char._go_ref = go
    if char._transform then
        local ok = pcall(char._transform.call, char._transform, "get_GameObject")
        if ok then return char._transform end
        char._transform = nil; char._joints = {}
    end
    local ok, t = pcall(go.call, go, "get_Transform")
    if ok and t then char._transform = t; return t end
    return nil
end

local function get_joint_cached(char, transform, joint_name)
    if char._joints[joint_name] then
        local ok = pcall(char._joints[joint_name].get_Position, char._joints[joint_name])
        if ok then return char._joints[joint_name] end
        char._joints[joint_name] = nil
    end
    local ok, j = pcall(transform.call, transform, "getJointByName", joint_name)
    if ok and j then char._joints[joint_name] = j; return j end
    return nil
end

local function measure_distance(char, go)
    local transform = ensure_transform(char, go)
    if not transform then return nil end
    local lj = get_joint_cached(char, transform, "L_Arm_Hand")
    local rj = get_joint_cached(char, transform, "R_Arm_Hand")
    if not lj or not rj then return nil end
    local lp = lj:call("get_Position")
    local rp = rj:call("get_Position")
    if not lp or not rp then return nil end
    local dx = lp.x - rp.x
    local dy = lp.y - rp.y
    local dz = lp.z - rp.z
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
    char._last_dist = dist
    return dist
end

local function check_distance(char, go, group_id)
    local now = os.clock()
    local cached = char._dist_cache[group_id]
    if cached and (now - cached.time) < char.distance_interval then
        return cached.result, cached.distance
    end
    local dist = measure_distance(char, go)
    if dist == nil then return nil, nil end
    local result = dist < get_active_threshold(char)
    char._dist_cache[group_id] = { time = now, distance = dist, result = result }
    return result, dist
end

------------------------------------------------------
-- Core: IK state control
------------------------------------------------------
local function set_ik_state(item, enable_val, disable_val)
    local cur_e = item:read_qword(OFFSET_ENABLE)
    local cur_d = item:read_qword(OFFSET_DISABLE)
    if cur_e == enable_val and cur_d == disable_val then return false end
    item:write_qword(OFFSET_ENABLE, enable_val)
    item:write_qword(OFFSET_DISABLE, disable_val)
    return true
end

local function restore_char(char)
    if not char.ik_forced then return end
    if char._go_ref then
        local item = find_ik_item(char, char._go_ref)
        if item then set_ik_state(item, 0, 1) end
    end
    char.ik_forced = false
end

local function restore_all()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return end
    local scene = sdk.call_native_func(sm,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end
    for _, char in ipairs(characters) do
        restore_char(char)
        char.status = "Disabled, IK restored"
    end
end

------------------------------------------------------
-- Main check logic
------------------------------------------------------
local function check_conditional(char, go)
    local layers = get_layer_data(char, go)
    local item = find_ik_item(char, go)

    -- Force measure for real-time UI display when debug is on
    if cfg.debug then
        measure_distance(char, go)
    end

    -- Kill conditions: immediate disable
    if match_condition_groups(layers, char.kill_conditions) then
        if item and char.ik_forced then set_ik_state(item, 0, 1) end
        char.ik_forced = false
        char.status = "Kill condition, IK OFF"
        char.active_condition_str = "Kill Condition"
        return
    end

    -- Match enable conditions
    local matched_group = match_conditions(layers, char.conditions, char)
    local active = matched_group ~= nil
    local dist_info = ""

    if active then
        -- Generate readable string of the matched condition
        local parts = {}
        for _, c in ipairs(matched_group.checks or matched_group) do
            local inv = c._invert and "NOT " or ""
            table.insert(parts, string.format("%sL%d b:%s m:%s",
                inv, c.layer or -1,
                c.bank ~= nil and tostring(c.bank) or "*",
                c.mot  ~= nil and tostring(c.mot)  or "*"))
        end
        char.active_condition_str = "(" .. table.concat(parts, " AND ") .. ")"
        if matched_group.distance_check then
            char.active_condition_str = char.active_condition_str .. " [dist]"
        end
    else
        char.active_condition_str = "None"
    end

    -- Grace-style: distance_check on conflict groups (正向：距离<阈值才启用)
    if active and matched_group.distance_check then
        local group_id = tostring(matched_group)
        local close, dist = check_distance(char, go, group_id)
        if close == nil then
            active = false
            dist_info = " (dist: N/A)"
        elseif close then
            char._dist_grace_end = nil  -- 手靠近，彻底重置保护期
            dist_info = string.format(" (dist: %.3fm)", dist)
        else
            -- 距离超出，检查是否有保护期
            if matched_group.distance_grace then
                local now = os.clock()
                
                -- 只有在值为 nil（刚从满足变为不满足）时才赋予倒计时
                if char._dist_grace_end == nil then
                    char._dist_grace_end = now + matched_group.distance_grace
                end
                
                -- 判断还在倒计时内（大于0说明在计时，且 now 没超过设定时间）
                if char._dist_grace_end > 0 and now < char._dist_grace_end then
                    -- 保护期内维持 active
                    dist_info = string.format(" (grace: %.2fs)", char._dist_grace_end - now)
                else
                    active = false
                    -- 标记为 -1，表示保护期已用完，避免下一帧无限重复触发
                    char._dist_grace_end = -1
                    dist_info = string.format(" (dist: %.3fm >= %.3f)", dist, get_active_threshold(char))
                end
            else
                active = false
                dist_info = string.format(" (dist: %.3fm >= %.3f)", dist, get_active_threshold(char))
            end
        end
    end

    -- Leon-style: distance_sustain (反向：IK已启用，条件不匹配，距离<阈值就维持)
    if not active and char.ik_forced and char.distance_sustain then
        local close, dist = check_distance(char, go, "sustain")
        if close == nil then
            -- 无法测量，保守维持
            active = true
            dist_info = " (sustain: dist N/A, keeping)"
        elseif close then
            -- 手还在附近，维持IK
            active = true
            dist_info = string.format(" (sustain: %.3fm)", dist)
        else
            -- 手远离了，撤销IK
            active = false
            dist_info = string.format(" (sustain lost: %.3fm >= %.3f)", dist, get_active_threshold(char))
        end
    end

    if not item then
        char.status = (active and "Active" or "Idle") .. ", IK not found"
        return
    end

    if active then
        local changed = set_ik_state(item, 1, 0)
        if changed then char.fix_count = char.fix_count + 1 end
        char.ik_forced = true
        if char.weapon_distance_thresholds and WeaponPoseFix then
            local w = WeaponPoseFix.active_weapon and WeaponPoseFix.active_weapon[char.name]
            if w then char._last_weapon = w end
        end
        char.status = string.format("Active, IK ON (fixes: %d)%s", char.fix_count, dist_info)
    else
        if char.ik_forced then
            set_ik_state(item, 0, 1)
            char.ik_forced = false
            char._last_weapon = nil
        end
        char.status = "Idle, IK OFF" .. dist_info
    end
end

------------------------------------------------------
-- Main loop
------------------------------------------------------
re.on_frame(function()
    if prev_enabled and not cfg.enabled then
        pcall(restore_all)
    end
    prev_enabled = cfg.enabled

    if not cfg.enabled then return end
    local now = os.clock()
    if now - last_layer_check < cfg.layer_interval then return end
    last_layer_check = now

    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return end
    local scene = sdk.call_native_func(sm,
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if not scene then return end

    for _, char in ipairs(characters) do
        if not char.char_enabled then
            if char.ik_forced then
                restore_char(char)
                char.status = "Char disabled, IK restored"
            else
                char.status = "Char disabled"
            end
        else
            -- Use cached GameObject if valid
            local go = char._go_ref
            if go then
                local ok = pcall(function() return go:get_Name() end)
                if not ok then go = nil end
            end
            
            -- Re-find if lost
            if not go then
                go = scene:call("findGameObject(System.String)", char.go_name)
                char._go_ref = go
            end
            
            if go then
                pcall(check_conditional, char, go)
                if char.arm_weapon_map then
                    pcall(update_detected_weapon, char)
                end
            else
                char.status = "Not in scene"
                char._transform = nil; char._joints = {}; char._dist_cache = {}; char._go_ref = nil; char._ik_item = nil
            end
        end
    end
end)

------------------------------------------------------
-- UI
------------------------------------------------------
local function conditions_string(conditions)
    if not conditions then return "(none)" end
    local groups = {}
    for _, group in ipairs(conditions) do
        local checks = group.checks or group
        local parts = {}
        for _, c in ipairs(checks) do
            local inv = c._invert and "NOT " or ""
            table.insert(parts, string.format("%sL%d b:%s m:%s",
                inv, c.layer or -1,
                c.bank ~= nil and tostring(c.bank) or "*",
                c.mot  ~= nil and tostring(c.mot)  or "*"))
        end
        local suffix = group.distance_check and " [dist]" or ""
        if group.weapons then
            suffix = suffix .. " [only:" .. table.concat(group.weapons, ",") .. "]"
        end
        if group.weapons_exclude then
            suffix = suffix .. " [excl:" .. table.concat(group.weapons_exclude, ",") .. "]"
        end
        table.insert(groups, "(" .. table.concat(parts, " AND ") .. ")" .. suffix)
    end
    return table.concat(groups, "\n  OR ")
end

local function kill_conditions_string(kill_conditions)
    if not kill_conditions then return "(none)" end
    local groups = {}
    for _, group in ipairs(kill_conditions) do
        local parts = {}
        for _, c in ipairs(group) do
            local inv = c._invert and "NOT " or ""
            table.insert(parts, string.format("%sL%d b:%s m:%s",
                inv, c.layer or -1,
                c.bank ~= nil and tostring(c.bank) or "*",
                c.mot  ~= nil and tostring(c.mot)  or "*"))
        end
        table.insert(groups, "(" .. table.concat(parts, " AND ") .. ")")
    end
    return table.concat(groups, " OR ")
end

re.on_draw_ui(function()
    if imgui.collapsing_header("IK LHand Fix") then
        local changed_global, new_global = imgui.checkbox("Global Enabled", cfg.enabled)
        if changed_global then cfg.enabled = new_global end
        
        local changed_dbg, new_dbg = imgui.checkbox("Debug Mode", cfg.debug)
        if changed_dbg then cfg.debug = new_dbg end
        imgui.separator()

        for _, char in ipairs(characters) do
            imgui.push_id(char.name)
            if imgui.tree_node(char.name .. " (" .. char.go_name .. ")") then
                local changed_en, new_en = imgui.checkbox("Enabled", char.char_enabled)
                if changed_en then
                    char.char_enabled = new_en
                    save_char_config(char)
                end

                local changed_dt, new_dt = imgui.slider_float("Distance threshold (m)",
                    char.distance_threshold, 0.01, 0.5, "%.3f")
                if changed_dt then
                    char.distance_threshold = new_dt
                    char._dist_cache = {}
                    save_char_config(char)
                end

                if char.distance_sustain then
                    imgui.text("[distance_sustain: ON]")
                end

                -- Per-weapon distance thresholds (Leon only)
                if char.weapon_distance_thresholds then
                    local weapon_order = { "Pistol", "Shotgun", "Grenade", "Melee", "Magnum", "SMG", "Sniper" }
                    local current_weapon = (WeaponPoseFix and WeaponPoseFix.active_weapon and WeaponPoseFix.active_weapon[char.name])
                                       or char._detected_weapon
                    imgui.separator()
                    imgui.text("Per-Weapon Distance Threshold:")
                    for _, wname in ipairs(weapon_order) do
                        if char.weapon_distance_thresholds[wname] ~= nil then
                            local label = (wname == current_weapon) and (wname .. " [active]") or wname
                            local changed_wt, new_wt = imgui.slider_float(
                                label .. "##wdt_" .. char.name,
                                char.weapon_distance_thresholds[wname],
                                0.01, 0.5, "%.3f")
                            if changed_wt then
                                char.weapon_distance_thresholds[wname] = new_wt
                                char._dist_cache = {}
                                save_char_config(char)
                            end
                        end
                    end
                end

                if cfg.debug then
                    imgui.text("Weapon: " .. get_current_weapon(char))
                    imgui.text("Enable:\n  " .. conditions_string(char.conditions))
                    imgui.text("Kill: " .. kill_conditions_string(char.kill_conditions))
                    imgui.text(string.format("Config: %s", char.config_source))
                end
                
                imgui.text("Status: " .. char.status)
                
                if cfg.debug then
                    imgui.text("Matched: " .. (char.active_condition_str or "None"))
                    if char._last_dist then
                        imgui.text(string.format("Distance: %.3fm", char._last_dist))
                    end

                    if imgui.button("Reload Config") then
                        load_char_config(char)
                    end
                end

                imgui.tree_pop()
            end
            imgui.pop_id()
        end
    end
end)

log.info("[IK LHand Fix] Loaded.")