-------------------------------------------------------------------------------
--  EllesmereUIQoL_RaidTools.lua -- Raid control panels (QoL: Raid Tools page)
--
--  THREE content groups -- Group & Pull (ready/role/convert/disband + the pull
--  timer; plain buttons), Markers (target row + world row; secure buttons,
--  placeable mid-combat) and Raid Groups (which subgroups the raid frames
--  draw) -- shown either as one combined window (default) or as independently
--  positioned windows.
--
--  SHOW MODE (p.mode) replaces the old shared-visibility system outright:
--
--    "never"  -- the default. NOTHING exists: no frames, no events, no
--                bindings, no unlock rows. True zero cost.
--    "raid"   -- auto-shows in a raid group ([group:raid] state driver).
--    "group"  -- auto-shows in any group ([group] state driver).
--    "always" -- always shown (no driver; the visible attribute just stays
--                true).
--
--  The Toggle Raid Tools keybind works in every active mode, and what it
--  toggles follows Default to Collapsed When Shown: with it ON the key rocks
--  between the collapsed icon and the full windows (the icon is the minimized
--  state, so hiding would be redundant); with it OFF the key is a plain
--  show/hide of the full windows, riding the override on top of the mode's
--  verdict. In the driver modes a TRANSITION reclaims control; in always
--  mode the override holds until the next settings pass.
--
--  COMBAT MODEL -- read this before changing anything here.
--
--  Marker buttons are SecureActionButtonTemplate, built once on first
--  non-never Apply and never re-anchored, re-parented or resized in combat.
--  The window shells are SecureHandlerState frames, which makes THEM
--  protected; that dictates who may change visibility, and when:
--
--    * The STATE DRIVER, the KEYBIND, the collapsed icon's expand click and
--      the collapse buttons all work in combat -- every one is a hardware
--      click or driver transition running the secure "apply" snippet.
--    * LUA does not. Show/Hide AND SetAttribute on a protected frame are
--      blocked in lockdown, so every options-driven change (mode, layout,
--      scale, position) defers behind applyPending and completes on
--      PLAYER_REGEN_ENABLED.
--
--  VISIBILITY STATE -- attributes on each shell and on the collapsed icon,
--  one writer each:
--
--    enabled       -- may this frame ever show. Written by Apply, OOC only.
--    visible       -- the driver's current verdict; false when no driver.
--                     Written by _onstate (and Apply's OOC settle).
--    override      -- "" / "show" / "hide" from the keybind; cleared by
--                     driver transitions and settings passes.
--    expanded      -- windows (true) vs collapsed icon (false). Flipped by
--                     the icon's expand click and the collapse buttons;
--                     re-seeded from startexpanded on driver transitions and
--                     on every keybind "show".
--    startexpanded -- the seed for EVERY show (driver, settings pass,
--                     keybind): NOT Default to Collapsed When Shown. Turning
--                     that toggle off is how the keybind becomes a plain
--                     full-window toggle.
--
--  "apply" folds these into Show/Hide: shells show when visible-and-expanded,
--  the icon shows when visible-and-collapsed. It is the ONLY place any of
--  these frames is shown or hidden.
--
--  SHOW AS owns the window composition outright -- there are no separate
--  per-panel enable toggles. Two INDEPENDENT axes, because four named values
--  ("one"/"two"/"group"/"markers") could not survive a third content group:
--  the combinations grow as 2^n while the names grow as n.
--
--    p.windows -- a set: which content groups are on screen at all. Any
--                 combination; the options control refuses to uncheck the
--                 last one, so at least one is always present.
--    p.combine -- true (the default): every checked group shares ONE shell,
--                 which grows to fit, retitles to "Raid Tools" and carries the
--                 single unlock element. False: each checked group gets its
--                 own shell and its own unlock element.
--
--  Holders re-parent (OOC) into whichever shell hosts them; they are plain
--  frames, so the move is an ordinary SetParent and the secure marker buttons
--  never change parents themselves.
--
--  The PRIMARY window -- the first checked group in SECTION_KEYS order -- is
--  the one that hosts the combined shell, anchors the collapsed icon and
--  carries the collapse button. A second collapse control on another shell
--  would just be a duplicate: one button folds the whole feature.
--
--  p.showAs is the retired v8.6.6 form, converted across every saved profile
--  by raidtools_showas_to_windows_v1 in EllesmereUI_Migration.lua. Nothing
--  here reads it.
--
--  One Window Scale (p.scale) covers every form: every shell and the collapsed
--  icon wear the same value, whichever windows are on screen.
-------------------------------------------------------------------------------
local _, ns = ...

local InCombatLockdown = InCombatLockdown
local UnitIsGroupLeader, UnitIsGroupAssistant = UnitIsGroupLeader, UnitIsGroupAssistant
local IsInRaid, IsInGroup = IsInRaid, IsInGroup
local SetRaidTargetIconTexture = SetRaidTargetIconTexture

-- Layout constants. Content geometry is decided once at build; only scale,
-- and which holders a shell carries, are user-facing.
local PANEL_W      = 236
local PAD          = 10
local TOPBAR_H     = 25    -- the Window Skins title band
local CONTENT_TOP  = TOPBAR_H + 6
local ROW_H        = 22
local ROW_GAP      = 4
-- Marker buttons span the full panel width regardless of this size: the row
-- step is derived from it ((PANEL_W - PAD*2 - MARKER_SZ) / 8), so a smaller
-- icon just breathes more between neighbours.
local MARKER_SZ    = 23
local MARKER_LBL_H = 10
local ICON_SZ      = 30
local PULL_SLOTS   = 3
local PULL_DEFAULTS = { 3, 5, 10 }   -- also seeded into DB_DEFAULTS below
ns.PULL_DEFAULTS = PULL_DEFAULTS

-------------------------------------------------------------------------------
--  Window Skins look, replicated
--
--  These panels wear the same dress as the Blizz UI Enhanced window skins:
--  the modern_blizz art cover-fit behind a 0.62 black wash, a 25px black
--  title band, the AdventureMap_TopBorder frame atlas (1px gray fallback),
--  and flat 0.08-gray buttons with a 1px 0.2-gray border and a white 0.1
--  hover. The values are copied from the WSkin engine's Shell/Button recipe
--  ON PURPOSE rather than calling it: WSkin lives in EllesmereUIBlizzardSkin,
--  a sibling child addon the user may not have enabled, and QoL must not
--  depend on it.
-------------------------------------------------------------------------------
local SKIN_BG_TEX  = "Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png"
-- Cover-fit crop window into the art (same numbers as the WSkin engine).
local BG_ASPECT = 561 / 433
local BASE_L, BASE_R, BASE_T, BASE_B = 0.25, 1, 0, 0.75
local BASE_U, BASE_V = BASE_R - BASE_L, BASE_B - BASE_T
local BORDER_ATLAS = "AdventureMap_TopBorder"
-- Theme grays (WSkin.Theme): button fill / border line.
local BTN_R, BTN_G, BTN_B, BTN_A = 0.08, 0.08, 0.08, 0.92
local BRD_R, BRD_G, BRD_B, BRD_A = 0.2, 0.2, 0.2, 1

-- Shell backdrop: art + wash + title band, and a re-crop function the layout
-- pass calls after any height change so the art never stretches.
local function SkinPanelBg(f)
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetTexture(SKIN_BG_TEX)
    bg:SetAllPoints(f)
    local overlay = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    overlay:SetColorTexture(0, 0, 0, 0.62)
    overlay:SetAllPoints(f)
    local topBar = f:CreateTexture(nil, "BACKGROUND", nil, -5)
    topBar:SetColorTexture(0, 0, 0, 0.5)
    topBar:SetPoint("TOPLEFT")
    topBar:SetPoint("TOPRIGHT")
    topBar:SetHeight(TOPBAR_H)
    f._bgFit = function()
        local fw, fh = f:GetSize()
        if not fw or fw == 0 or not fh or fh == 0 then return end
        local fa = fw / fh
        if fa > BG_ASPECT then
            local visV = BASE_V * (BG_ASPECT / fa)
            local trimV = (BASE_V - visV) / 2
            bg:SetTexCoord(BASE_L, BASE_R, BASE_T + trimV, BASE_B - trimV)
        else
            local visU = BASE_U * (fa / BG_ASPECT)
            local trimU = (BASE_U - visU) / 2
            bg:SetTexCoord(BASE_L + trimU, BASE_R - trimU, BASE_T, BASE_B)
        end
    end
    f._bgFit()
end

-- Window frame: the atlas border the skins use, 1px gray line if the atlas
-- ever disappears from the client.
local function SkinPanelBorder(f)
    local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(BORDER_ATLAS)
    if not info then
        EllesmereUI.MakeBorder(f, BRD_R, BRD_G, BRD_B, BRD_A, EllesmereUI.PP)
        return
    end
    local ov = CreateFrame("Frame", nil, f)
    ov:SetAllPoints(f)
    ov:SetFrameLevel(f:GetFrameLevel() + 6)
    local tex = ov:CreateTexture(nil, "OVERLAY", nil, 7)
    tex:SetAtlas(BORDER_ATLAS)
    tex:SetAllPoints(ov)
end

-- Button chrome: flat fill, 1px line, white hover on the HIGHLIGHT layer
-- (Buttons show that layer on mouseover natively, so no scripts).
local function SkinButtonChrome(b)
    local fill = b:CreateTexture(nil, "BACKGROUND")
    fill:SetColorTexture(BTN_R, BTN_G, BTN_B, BTN_A)
    fill:SetAllPoints(b)
    EllesmereUI.MakeBorder(b, BRD_R, BRD_G, BRD_B, BRD_A, EllesmereUI.PP)
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetColorTexture(1, 1, 1, 0.1)
    hover:SetAllPoints(b)
end

-- The collapsed-state button IS this image: no chrome, no border, no inset.
local COLLAPSED_ICON_TEX = "Interface\\AddOns\\EllesmereUI\\media\\icons\\raid-tools.png"

-- Canonical section list. Stack order, DB key set, window composition, window
-- titles and unlock-mover labels all derive from this one table -- adding a row
-- changes all of those with no other edit. Building the content is the one part
-- that stays hand-wired: each group draws something different, so a fourth
-- would also need its Build...Content function called from BuildAll.
--
-- `label` reaches EllesmereUI.L as a variable, which the static key extractor
-- cannot see -- the documented arrangement for exactly this case (see the
-- header of .tools/extract-locale-keys.sh); the in-game /euiloc harvester picks
-- them up, the same way every widget label in the suite is already handled.
local SECTIONS = {
    { key = "Group",      label = "Group & Pull" },
    { key = "Markers",    label = "Markers" },
    -- "Visibility", not "Raid Groups": this panel only chooses which subgroups
    -- the raid frames draw. The window that actually moves people between
    -- subgroups is a different feature, and two things called the same thing
    -- is how a raid leader clicks the wrong one. The KEY stays RaidGroups --
    -- it persists in saved anchors and renaming it breaks existing links.
    { key = "RaidGroups", label = "Raid Group Visibility" },
}
-- The options page builds its window checklist from this, so the control can
-- never offer a window the runtime does not have.
ns.SECTIONS = SECTIONS

-- One-window title; reaches L as a variable like the section labels.
local COMBINED_LABEL = "Raid Tools"

-- Prefix for this feature's unlock-mode element keys. Used both to register
-- them and to ask the anchor system about them, so the two cannot drift.
-- These keys persist in saved anchors -- renaming breaks existing links.
local UNLOCK_KEY = "EUI_RaidTools_"

local SECTION_KEYS = {}
local SECTION_LABEL = {}
for _, def in ipairs(SECTIONS) do
    SECTION_KEYS[#SECTION_KEYS + 1] = def.key
    SECTION_LABEL[def.key] = def.label
end

local db
local applyPending             -- true when combat blocked an Apply()
local previewOn = false        -- Raid Tools settings page is in front (see ApplyVisibility)
local toggleButton             -- keybind target; also the out-of-combat path
local sections = {}            -- key -> shell frame
local shellTitle = {}          -- key -> title fontstring
local holders = {}             -- key -> plain content holder (see header)
local iconBtn                  -- collapsed-state square
local groupsPending            -- true when combat blocked a raid-frame re-render
local Apply                    -- forward: the event handler closes over it

-- ONE representation of each secure decision, run from both paths.
--
-- The keybind clicks the button, which is the only thing that works during
-- combat. Out of combat the same snippet is run through SecureHandlerExecute
-- instead of being re-implemented in Lua. EllesmereUIRaidFrames.lua does
-- exactly this, for exactly this reason: the driver manager only fires the
-- attribute handlers on value CHANGES, so a reapply with unchanged states
-- would otherwise never run.
local RUN_APPLY = [[ self:RunAttribute("apply") ]]

-- The keybind's job depends on Default to Collapsed When Shown:
--
--   ON  -- the icon IS the minimized state, so hiding would be redundant.
--          The key rocks between the icon and the full windows (collapse /
--          expand); from fully hidden it shows the windows directly, since
--          the press means the tools are wanted NOW.
--   OFF -- a plain show/hide of the full windows.
--
-- The branch is read off the icon's startexpanded (false = collapse mode),
-- so the snippet needs no config attribute of its own.
local TOGGLE_SNIPPET = [[
    local n = self:GetAttribute("count") or 0
    local icon = self:GetFrameRef("icon")
    local anyWin, iconShown = false, false
    for i = 1, n do
        local f = self:GetFrameRef("s" .. i)
        if f and f:IsShown() then anyWin = true end
    end
    if icon and icon:IsShown() then iconShown = true end

    local collapseMode = icon and not icon:GetAttribute("startexpanded")
    if collapseMode then
        if anyWin then
            -- Windows up: collapse to the icon. Visibility is untouched, so
            -- whatever put the windows up (driver or override) keeps the icon
            -- up in their place.
            for i = 1, n do
                local f = self:GetFrameRef("s" .. i)
                if f then
                    f:SetAttribute("expanded", false)
                    f:RunAttribute("apply")
                end
            end
            icon:SetAttribute("expanded", false)
            icon:RunAttribute("apply")
        else
            -- Icon up, or nothing up: expand to the windows. The override
            -- also covers the fully-hidden case (driver currently saying no).
            for i = 1, n do
                local f = self:GetFrameRef("s" .. i)
                if f then
                    f:SetAttribute("override", "show")
                    f:SetAttribute("expanded", true)
                    f:RunAttribute("apply")
                end
            end
            icon:SetAttribute("override", "show")
            icon:SetAttribute("expanded", true)
            icon:RunAttribute("apply")
        end
        return
    end

    local ov
    if anyWin or iconShown then ov = "hide" else ov = "show" end
    for i = 1, n do
        local f = self:GetFrameRef("s" .. i)
        if f then
            f:SetAttribute("override", ov)
            if ov == "show" then
                f:SetAttribute("expanded", f:GetAttribute("startexpanded"))
            end
            f:RunAttribute("apply")
        end
    end
    if icon then
        icon:SetAttribute("override", ov)
        if ov == "show" then
            icon:SetAttribute("expanded", icon:GetAttribute("startexpanded"))
        end
        icon:RunAttribute("apply")
    end
]]

-- Expand (the icon's own click) and collapse (the shells' corner buttons):
-- flip `expanded` everywhere and re-apply. Both run in combat as hardware
-- clicks on secure buttons.
local EXPAND_SNIPPET = [[
    local n = self:GetAttribute("count") or 0
    for i = 1, n do
        local f = self:GetFrameRef("s" .. i)
        if f then
            f:SetAttribute("expanded", true)
            f:RunAttribute("apply")
        end
    end
    self:SetAttribute("expanded", true)
    self:RunAttribute("apply")
]]
local COLLAPSE_SNIPPET = [[
    local n = self:GetAttribute("count") or 0
    for i = 1, n do
        local f = self:GetFrameRef("s" .. i)
        if f then
            f:SetAttribute("expanded", false)
            f:RunAttribute("apply")
        end
    end
    local icon = self:GetFrameRef("icon")
    if icon then
        icon:SetAttribute("expanded", false)
        icon:RunAttribute("apply")
    end
]]

-- Every fontstring is registered on the OUR-frame that owns it (`_fonts`),
-- and ApplyFonts walks the small fixed owner list -- no module-level registry
-- to keep in sync with frame lifetime. MakeFont (like every options-panel
-- helper) hardcodes the options-panel font; on-screen text has to resolve
-- through GetFontPath instead, or these panels would be the only ones in the
-- suite ignoring the Global Font setting.
local FONT_KEY = "extras"      -- QoL's key in EllesmereUI._addonKeyToFolder
local fontOwners = {}          -- filled at build: shells + holders
local function TrackFont(owner, fs, size)
    local t = owner._fonts
    if not t then t = {}; owner._fonts = t end
    t[#t + 1] = { fs = fs, size = size }
    return fs
end
local function ApplyFonts()
    local path = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath(FONT_KEY)
    if not path then return end
    for _, owner in ipairs(fontOwners) do
        local t = owner._fonts
        if t then
            for _, e in ipairs(t) do
                local _, _, flags = e.fs:GetFont()
                e.fs:SetFont(path, e.size, flags or "")
            end
        end
    end
end

local groupButtons = {}        -- plain buttons, enable-gated on assist
local markerButtons = {}       -- secure buttons, dimmed on assist
local pullButtons = {}         -- fixed set of 3; durations are re-labelled live
local raidGroupButtons = {}    -- plain buttons, gated on the raid frames only
local convertButton

-- Both marker rows draw Blizzard's own raid target sheet -- the texture the
-- rest of the suite already uses for markers, in nameplates and raid frames.
local MARKER_SHEET = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"

-- The sheet's SYMBOL order (1 Star, 2 Circle, 3 Diamond, 4 Triangle, 5 Moon,
-- 6 Square, 7 Cross, 8 Skull) is NOT the WORLD marker ID order (1 Blue,
-- 2 Green, 3 Purple, 4 Red, 5 Yellow, 6 Orange, 7 Silver, 8 White). Each
-- flare carries its symbol, so the button shows the symbol and this maps it
-- to the flare that actually wears it -- without it, clicking Star (symbol 1)
-- dropped the BLUE flare (world ID 1).
local SYMBOL_TO_WORLD = { 5, 6, 3, 2, 7, 1, 4, 8 }

-- One slice of the shared EllesmereUIQoLDB profile, the same arrangement
-- BattleRes and Bloodlust use: each QoL feature merges its own defaults into
-- the SAME profile table under its own key.
local DB_DEFAULTS = {
  profile = {
    raidTools = {
        -- "never" | "raid" | "group" | "always" (see header). Never = the
        -- feature does not exist at runtime.
        mode          = "never",
        -- Toggle Raid Tools key ("SHIFT-R" form). Profile-stored and applied
        -- as an override binding, exactly like Action Bars' toggleVisKey.
        toggleKey     = false,
        -- Default to Collapsed When Shown: EVERY show (driver, settings pass,
        -- keybind) starts as the small icon; click it to expand. Turning this
        -- off makes the keybind a plain full-window toggle.
        collapsedIcon = true,
        -- Window composition (see header). Cumulative set + a combine flag;
        -- there are no per-panel enable toggles. The v8.6.6 showAs string is
        -- converted by raidtools_showas_to_windows_v1 in EllesmereUI_Migration
        -- .lua, which runs across every saved profile -- not just the active
        -- one -- before this default can apply.
        windows       = { Group = true, Markers = true, RaidGroups = true },
        combine       = true,
        -- One scale for the whole feature: whichever windows the Show as
        -- choice puts on screen (and the collapsed icon) all wear it.
        scale         = 1,
        -- Three slots is a LAYOUT choice (they fill one row beside Stop), not
        -- a security constraint -- the pull buttons are plain, only the marker
        -- buttons are secure. Growing the count later means growing the panel,
        -- nothing more.
        pullTimes     = { PULL_DEFAULTS[1], PULL_DEFAULTS[2], PULL_DEFAULTS[3] },
        -- Per-section: pos[key] = { point, relPoint, x, y }
        pos           = {},
    },
  },
}

-- Our slice of the shared QoL profile, re-derived on every read -- the same
-- accessor BattleRes and MovementAlert use. Deliberately NOT cached: a profile
-- switch replaces the whole profile table, and a cached pointer would leave
-- the event handler, the slash command and the unlock callbacks writing into
-- an orphaned table.
--
-- A PURE READ, with no `or {}` seeding. Spec Overrides captures a page by
-- swapping the profile tables for read-tracking proxies: reading a table value
-- hands back a NEW proxy, and writing goes through to the real table. So
-- `t.x = t.x or {}` stores a proxy inside the real table, the next call wraps
-- that proxy in another, and reading through the stack overflows the C stack.
-- DB_DEFAULTS already guarantees the slice exists; the seeding was never
-- needed and is actively harmful here.
local function P()
    return db and db.profile and db.profile.raidTools
end

local function Mode()
    local p = P()
    return (p and p.mode) or "never"
end

-- Is this content group on screen at all? A missing key reads as on, which is
-- how a content group added in a later version arrives switched on rather than
-- invisible until the user finds the control.
local function WindowOn(key)
    local p = P()
    local w = p and p.windows
    return not w or w[key] ~= false
end
ns.WindowOn = WindowOn

local function Combined()
    local p = P()
    return not p or p.combine ~= false
end
ns.Combined = Combined

-- The first checked content group in canonical order: hosts the combined
-- shell, anchors the collapsed icon, carries the collapse button. Never nil --
-- the options control keeps at least one checked, and a profile hand-edited to
-- none still resolves to the first key rather than leaving the feature
-- unreachable.
local function PrimaryWindow()
    for _, key in ipairs(SECTION_KEYS) do
        if WindowOn(key) then return key end
    end
    return SECTION_KEYS[1]
end

-- Does this key own a shell on screen? Combined mode puts everything in the
-- primary's shell, so only that one is live. The single predicate behind
-- visibility, positioning, the default stack and the unlock rows -- they
-- cannot disagree.
local function ShellActive(key)
    if Combined() then return key == PrimaryWindow() end
    return WindowOn(key)
end

-- The options page is a pure view: it holds no rule of its own, so a profile
-- import or any future writer inherits this guard rather than re-deriving it.
--
-- Refuses to uncheck the last window. An empty set would leave the feature
-- enabled with nothing on screen, and the only way back would be the control
-- that just emptied it.
function ns.SetWindowOn(key, on)
    local p = P()
    local w = p and p.windows
    if not w then return end
    if not on then
        local another = false
        for _, k in ipairs(SECTION_KEYS) do
            if k ~= key and WindowOn(k) then another = true; break end
        end
        if not another then return end
    end
    w[key] = on
    Apply()
end

local function WindowScale()
    local p = P()
    return (p and p.scale) or 1
end

-------------------------------------------------------------------------------
--  Suite-styled widgets
--
--  Window-skin chrome (SkinPanelBg/Border, SkinButtonChrome) plus the suite
--  font pipeline (GetFontPath via TrackFont), so the panels read as skinned
--  Blizzard windows rather than stock Blizzard UI or the options panel.
-------------------------------------------------------------------------------

-- Enable state without touching the button's own scripts: dimming the whole
-- frame and cutting mouse input is both
-- simpler and immune to a hover re-lighting a disabled control.
local function SetButtonEnabled(b, on)
    b:SetAlpha(on and 1 or 0.35)
    b:EnableMouse(on)
end

-- Action button in the Window Skins style: flat fill, 1px line, white hover,
-- white label (WSkin.Button + WhiteButtonLabel, replicated).
--
-- `needsLeader` narrows the gate from assist to leader. `registry` is the list
-- RefreshPermissions walks; the raid group toggles pass their own, because they
-- change what THIS client draws and so are never permission-gated -- but they
-- want the identical chrome, and a second constructor would drift from this one
-- the first time the skin moves.
local function MakeGroupButton(parent, text, width, onClick, needsLeader, registry)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, ROW_H)
    SkinButtonChrome(b)
    local lbl = TrackFont(parent, EllesmereUI.MakeFont(b, 11, nil, 1, 1, 1), 11)
    lbl:SetPoint("CENTER")
    if text ~= "" then lbl:SetText(EllesmereUI.L(text)) end
    b:SetScript("OnClick", onClick)
    b._lbl = lbl
    b.needsLeader = needsLeader
    registry = registry or groupButtons
    registry[#registry + 1] = b
    return b
end

-- Secure marker button. Action attributes are set here, at build, and never
-- touched again -- that is what makes them usable in combat.
--
-- The attribute names are SecureActionButtonTemplate's own contract, so two
-- details are dictated rather than chosen:
--   * slash commands are read from the SLASH_* globals. They are localized --
--     writing "/tm" or "/cwm" as a literal breaks every non-English client,
--     including this one.
--   * the worldmarker type takes `marker` as a STRING, and splits placing from
--     clearing across action1 and action2.
local function MakeMarkerButton(parent, index, kind)
    local b = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    b:SetSize(MARKER_SZ, MARKER_SZ)
    -- One phase only: the "!" prefix toggles the marker, so firing on both the
    -- down and the up would set it and immediately clear it again.
    b:RegisterForClicks("AnyDown")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    b.icon = icon

    if kind == "target" then
        -- Left: toggle this marker on the target. Right: clear it.
        b:SetAttribute("type", "macro")
        if index == 0 then
            b:SetAttribute("macrotext", (SLASH_TARGET_MARKER1 or "/tm") .. " 0")
        else
            b:SetAttribute("macrotext1", (SLASH_TARGET_MARKER1 or "/tm") .. " !" .. index)
            b:SetAttribute("macrotext2", (SLASH_TARGET_MARKER1 or "/tm") .. " 0")
        end
    elseif index == 0 then
        -- Clear-all is a macro, not a worldmarker action: the attribute form
        -- clears one index at a time.
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext",
            (SLASH_CLEAR_WORLD_MARKER1 or "/cwm") .. " " .. (ALL or "All"))
    else
        b:SetAttribute("type", "worldmarker")
        -- `index` is the SYMBOL the button shows; the attribute wants the
        -- world-marker ID of the flare carrying that symbol (see the map).
        b:SetAttribute("marker", tostring(SYMBOL_TO_WORLD[index]))
        b:SetAttribute("action1", "set")
        b:SetAttribute("action2", "clear")
    end

    if index == 0 then
        icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    else
        icon:SetTexture(MARKER_SHEET)
        SetRaidTargetIconTexture(icon, index)
    end

    -- No chrome on the marker grid: the symbols read best bare. Hover is an
    -- opacity lift on the icon itself (80% resting, 100% under the cursor),
    -- and the no-assist dim keeps priority -- a 0.4-dimmed button does not
    -- brighten on hover, so the dim never lies. _baseAlpha is ours to write
    -- (our CreateFrame'd button); RefreshPermissions owns its value.
    icon:SetAlpha(0.8)
    b._baseAlpha = 0.8
    b:SetScript("OnEnter", function(self)
        if (self._baseAlpha or 0.8) >= 0.8 then self.icon:SetAlpha(1) end
    end)
    b:SetScript("OnLeave", function(self)
        self.icon:SetAlpha(self._baseAlpha or 0.8)
    end)

    markerButtons[#markerButtons + 1] = b
    return b
end

-------------------------------------------------------------------------------
--  Raid group filter
--
--  Which subgroups the raid frames draw is a Raid Frames setting -- that module
--  already exposes it as a "Show Groups" checklist in its own options page.
--  This window is a second way to the same switch, reachable mid-raid instead
--  of three levels into the options window, so it drives that module directly
--  and keeps no copy of the state: every paint reads the live setting, so the
--  two controls cannot drift apart.
--
--  Both halves of the reach are the framework's own, not a new contract:
--  Lite.GetAddon(folder, silent) is how the parent reads a child's profile
--  (EllesmereUI_SpecOverrides.lua's LiteProfile), and _ERF_RefreshAll is
--  already registered as Raid Frames' refresh in that file's REFRESH_FNS. The
--  silent flag returning nil for a missing addon IS the fallback detection.
--
--  Nothing here is gated on lead or assist: this changes what THIS client
--  draws and takes nothing from anyone.
-------------------------------------------------------------------------------
local RAID_GROUPS = 8
-- Both reach L as variables, like MARKER_ROWS. The second replaces the first
-- in the row's own label slot when there is nothing to drive: it explains the
-- greyed buttons without costing a line of height, so the window keeps the
-- geometry ApplyLayout measured at build.
local RAIDGROUPS_ROW_LABEL   = "Groups"
local RAIDGROUPS_ROW_NO_RF   = "Requires EllesmereUI Raid Frames"
local raidGroupsRowLabel

-- Re-resolved on every call: nil while the Raid Frames addon is disabled, and
-- a profile switch repoints .profile underneath.
local function RaidFramesProfile()
    local get = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon
    local a = get and get("EllesmereUIRaidFrames", true)
    return a and a.db and a.db.profile
end

-- Matches how the raid frames themselves read it: absent means unfiltered.
-- Their DEFAULT is groups 1-6 (7 and 8 off), which this window shows as-is --
-- a second default here would be exactly the drift the design forbids.
local function GroupShown(index)
    local p = RaidFramesProfile()
    local vg = p and p.visibleGroups
    return not vg or vg[index] ~= false
end

local function SetGroupShown(index, on)
    local p = RaidFramesProfile()
    local vg = p and p.visibleGroups
    if not vg then return end
    vg[index] = on

    -- Applying this rebuilds secure group headers, which the game forbids in
    -- combat: their _LayoutGroupsImpl returns early under lockdown, and their
    -- own post-combat pass only re-lays out for roster and size-tier changes,
    -- so it would never pick this up. The setting lands now; the re-render
    -- waits for PLAYER_REGEN_ENABLED.
    --
    -- Deliberately caller-side. The deeper fix is a dirty flag where their
    -- layout bails plus a replay in their regen branch -- the pattern that
    -- module already runs three times over (anchorDirty, FB.applyDirty,
    -- XF.applyDirty) -- which would also fix every OTHER caller of
    -- _ERF_RefreshAll. That is a Raid Frames change and belongs to its own PR.
    if InCombatLockdown() then
        groupsPending = true
    elseif _G._ERF_RefreshAll then
        _G._ERF_RefreshAll()
    end
end

-- Accent numeral = this group is drawn. The colour is passed in rather than
-- resolved here: the caller repaints eight buttons from one accent read.
local function PaintRaidGroup(b, shown, ar, ag, ab)
    if shown then
        b._lbl:SetTextColor(ar, ag, ab, 1)
    else
        b._lbl:SetTextColor(1, 1, 1, 0.35)
    end
end

local function MakeRaidGroupButton(parent, index, width)
    -- Declared before the call: the click closure reaches the button through
    -- it, and `local b = ...` would not be in scope inside its own initializer.
    -- Same shape the pull buttons use.
    local b
    b = MakeGroupButton(parent, "", width, function()
        SetGroupShown(index, not GroupShown(index))
        PaintRaidGroup(b, GroupShown(index), EllesmereUI.GetAccentColor())
    end, nil, raidGroupButtons)
    b._lbl:SetText(tostring(index))
    return b
end

-- Repaints all eight, and cuts input when there are no EllesmereUI raid frames
-- to redraw.
--
-- That is the whole fallback for a user who runs the Blizzard raid frames (or
-- another addon's) instead. Driving Blizzard's own group filter was considered
-- and rejected: CompactRaidFrameManager is protected, and this filter is the
-- one part of it whose UI Blizzard has already removed -- the functions linger
-- but nothing exercises them, and there is no supported read to paint from.
-- Anyone who disabled our raid frames is using a replacement that carries its
-- own group filter anyway.
--
-- Memoized on the state it draws, the same reason RefreshPermissions is: this
-- runs on GROUP_ROSTER_UPDATE, which bursts through a raid night, and nothing
-- it reads changes on that event. `force` is for callers that have to repaint
-- regardless -- Apply, whose accent colour or fonts may have moved underneath.
local lastGroupsMask
local function RefreshRaidGroups(force)
    local p  = RaidFramesProfile()
    local vg = p and p.visibleGroups

    -- One integer standing for "everything this function would draw": the
    -- eight toggles plus whether there is anything to drive at all.
    local mask, bit = p and 1 or 0, 2
    for i = 1, RAID_GROUPS do
        if not vg or vg[i] ~= false then mask = mask + bit end
        bit = bit * 2
    end
    if not force and mask == lastGroupsMask then return end
    lastGroupsMask = mask

    local ar, ag, ab = EllesmereUI.GetAccentColor()
    for i, b in ipairs(raidGroupButtons) do
        SetButtonEnabled(b, p ~= nil)
        PaintRaidGroup(b, not vg or vg[i] ~= false, ar, ag, ab)
    end
    if raidGroupsRowLabel then
        raidGroupsRowLabel:SetText(EllesmereUI.L(
            p and RAIDGROUPS_ROW_LABEL or RAIDGROUPS_ROW_NO_RF))
    end
end

-------------------------------------------------------------------------------
--  Permission gating
-------------------------------------------------------------------------------

-- Ready check, role check, countdown and markers all require lead or assist.
--
-- Solo counts as permitted. You are the only member, so nothing is being taken
-- from anyone, and the game already no-ops whatever does not apply outside a
-- group -- gating it ourselves would only make the panels dead on a target
-- dummy for no reason.
local function HasAssist()
    if not IsInGroup() then return true end
    return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local function IsLeader()
    if not IsInGroup() then return true end
    return UnitIsGroupLeader("player")
end

-- Durations are the only pull-timer setting that can change at runtime: the
-- button count is fixed at build, so re-labelling is all it takes.
local function RefreshPullTimes()
    local times = (P() and P().pullTimes) or {}
    for i, b in ipairs(pullButtons) do
        local secs = times[i] or PULL_DEFAULTS[i]
        b.secs = secs
        b._lbl:SetText(tostring(secs))
    end
end

-- GROUP_ROSTER_UPDATE is one of the chattiest events in a raid -- it bursts on
-- every join, leave and zone-in -- while assist/leader/raid status changes a
-- handful of times a night. Memo the three inputs and bail when none moved.
-- `force` is for callers that have just built or rebuilt the buttons.
local lastAssist, lastLeader, lastRaid
local function RefreshPermissions(force)
    local assist, leader, raid = HasAssist(), IsLeader(), IsInRaid()
    if not force and assist == lastAssist and leader == lastLeader and raid == lastRaid then
        return
    end
    lastAssist, lastLeader, lastRaid = assist, leader, raid

    for _, b in ipairs(groupButtons) do
        if b.needsLeader then SetButtonEnabled(b, leader) else SetButtonEnabled(b, assist) end
    end

    -- Secure buttons: cosmetic only, never Enable/Disable (see header).
    -- 0.8 is the grid's resting opacity (hover lifts to 1); 0.4 is the
    -- no-assist dim, which also suppresses the hover lift.
    for _, b in ipairs(markerButtons) do
        b._baseAlpha = assist and 0.8 or 0.4
        b.icon:SetAlpha(b._baseAlpha)
    end

    if convertButton then
        convertButton._lbl:SetText(raid and EllesmereUI.L("Convert to Party")
                                         or EllesmereUI.L("Convert to Raid"))
    end
end

-------------------------------------------------------------------------------
--  Pull timer
--
--  A pull has to reach the whole raid, not just this client, so the countdown
--  is handed to whichever boss mod is loaded through its published slash
--  handler -- that is the thing that broadcasts the timer to everyone else --
--  and Blizzard's own countdown runs on top for anyone without one.
--
--  Blizzard's countdown travels through chat, so the client refuses it during
--  combat. The boss mod handoff happens first for that reason: it still works
--  there, and losing the in-game countdown is better than losing both.
-------------------------------------------------------------------------------

local function BossModPullHandler()
    return SlashCmdList.BIGWIGSPULL or SlashCmdList.DEADLYBOSSMODSPULL
end

local function ChatLocked()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
       and C_ChatInfo.InChatMessagingLockdown()
end

local function StartPull(secs)
    local handler = BossModPullHandler()
    if handler then handler(tostring(secs)) end
    if ChatLocked() then
        EllesmereUI.Print("|cff0cd29fEllesmereUI:|r " .. EllesmereUI.L("In-game countdown unavailable in combat; the boss mod pull timer still started."))
        return
    end
    C_PartyInfo.DoCountdown(secs)
end

local function StopPull()
    local handler = BossModPullHandler()
    if handler then handler("0") end
    if not ChatLocked() then C_PartyInfo.DoCountdown(0) end
end

-------------------------------------------------------------------------------
--  Group actions
-------------------------------------------------------------------------------

local function DisbandGroup()
    if not IsLeader() then return end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name and name ~= UnitName("player") then
                C_PartyInfo.UninviteUnit(name)
            end
        end
    else
        for i = 1, GetNumSubgroupMembers() do
            local name = UnitName("party" .. i)
            if name then C_PartyInfo.UninviteUnit(name) end
        end
    end
    C_PartyInfo.LeaveParty()
end

-- The suite's own confirm dialog, not StaticPopup: CONTRIBUTING is explicit
-- that confirmations use ShowConfirmPopup, and it is the one that inherits the
-- panel skin and the scale registry.
local function ConfirmDisband()
    EllesmereUI:ShowConfirmPopup({
        title       = "Disband Group",
        message     = "Disband the group?",
        confirmText = "Disband",
        cancelText  = "Cancel",
        onConfirm   = DisbandGroup,
    })
end

-------------------------------------------------------------------------------
--  Frames (built once, on first non-never Apply -- secure children forbid
--  rebuilding)
-------------------------------------------------------------------------------

-- One secure window shell. Returns the frame; content lives in the plain
-- holders, so the shell owns only chrome (bg, border, title, collapse button)
-- and the visibility state machine.
local function MakeShell(key)
    local f = CreateFrame("Frame", "EllesmereUIRaidTools" .. key, UIParent,
                          "SecureHandlerStateTemplate")
    f:SetWidth(PANEL_W)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:Hide()

    -- The Window Skins dress (see the block above).
    SkinPanelBg(f)
    SkinPanelBorder(f)

    -- Visibility state: see the header. "apply" is the ONLY place this frame
    -- is shown or hidden.
    f:SetAttribute("enabled", true)
    f:SetAttribute("visible", false)
    f:SetAttribute("override", "")
    f:SetAttribute("expanded", true)
    f:SetAttribute("startexpanded", true)
    f:SetAttribute("apply", [[
        if not self:GetAttribute("enabled") then
            self:Hide()
            return
        end
        local ov = self:GetAttribute("override")
        local vis
        if ov == "show" then
            vis = true
        elseif ov == "hide" then
            vis = false
        else
            vis = self:GetAttribute("visible")
        end
        if vis and self:GetAttribute("expanded") then
            self:Show()
        else
            self:Hide()
        end
    ]])
    -- A driver transition is a context change: it reclaims control from any
    -- manual override and re-seeds the collapsed/expanded form. The icon has
    -- no state template of its own (click templates do not dispatch _onstate),
    -- so each shell fans the verdict out to it -- both shells stamping the
    -- same values is idempotent.
    f:SetAttribute("_onstate-euirt_vis", [[
        local vis = (newstate == "show")
        self:SetAttribute("visible", vis)
        self:SetAttribute("override", "")
        self:SetAttribute("expanded", self:GetAttribute("startexpanded"))
        self:RunAttribute("apply")
        local icon = self:GetFrameRef("icon")
        if icon then
            icon:SetAttribute("visible", vis)
            icon:SetAttribute("override", "")
            icon:SetAttribute("expanded", self:GetAttribute("startexpanded"))
            icon:RunAttribute("apply")
        end
    ]])

    -- White title, vertically centered in the black band (the skins' title
    -- treatment; the accent stays on interactions, not chrome).
    local fs = TrackFont(f, EllesmereUI.MakeFont(f, 12, nil, 1, 1, 1), 12)
    fs:SetPoint("LEFT", f, "TOPLEFT", PAD, -TOPBAR_H / 2)
    fs:SetText(EllesmereUI.L(SECTION_LABEL[key]))
    shellTitle[key] = fs

    -- Collapse button: small secure corner control riding the title band,
    -- only meaningful (and only shown -- ApplyLayout owns that) while Default
    -- to Collapsed Icon is on. Wears the skins' button chrome.
    local col = CreateFrame("Button", nil, f, "SecureHandlerClickTemplate")
    col:SetSize(14, 14)
    col:SetPoint("RIGHT", f, "TOPRIGHT", -6, -TOPBAR_H / 2)
    col:RegisterForClicks("AnyDown")
    SkinButtonChrome(col)
    local colFs = TrackFont(f, EllesmereUI.MakeFont(col, 14, nil, 1, 1, 1), 14)
    colFs:SetPoint("CENTER", col, "CENTER", 0, 1)
    colFs:SetText("-")
    colFs:SetAlpha(0.7)
    col:SetScript("OnEnter", function() colFs:SetAlpha(1) end)
    col:SetScript("OnLeave", function() colFs:SetAlpha(0.7) end)
    col:SetAttribute("_onclick", COLLAPSE_SNIPPET)
    f._collapseBtn = col

    sections[key] = f
    fontOwners[#fontOwners + 1] = f
    return f
end

-- Group & Pull content, in its own plain holder so one-window mode can treat
-- it uniformly with the markers holder.
local function BuildGroupContent()
    holders.Group = CreateFrame("Frame", nil, sections.Group)
    holders.Group:SetWidth(PANEL_W)
    fontOwners[#fontOwners + 1] = holders.Group
    local f = holders.Group
    local y = 0

    -- MakeGroupButton runs labels through L itself.
    local half = (PANEL_W - PAD * 2 - ROW_GAP) / 2
    local ready = MakeGroupButton(f, "Ready Check", half, function() DoReadyCheck() end)
    ready:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)

    local role = MakeGroupButton(f, "Role Check", half, function() InitiateRolePoll() end)
    role:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + half + ROW_GAP, y)
    y = y - ROW_H - ROW_GAP

    convertButton = MakeGroupButton(f, "Convert to Raid", half, function()
        if IsInRaid() then C_PartyInfo.ConvertToParty() else C_PartyInfo.ConvertToRaid() end
    end, true)
    convertButton:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)

    local disband = MakeGroupButton(f, "Disband", half, function()
        ConfirmDisband()
    end, true)
    disband:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + half + ROW_GAP, y)
    y = y - ROW_H - ROW_GAP

    -- Pull timer row: three durations + Stop, sharing the holder's width.
    local w = (PANEL_W - PAD * 2 - PULL_SLOTS * ROW_GAP) / (PULL_SLOTS + 1)
    for i = 1, PULL_SLOTS do
        -- The pull duration lives on the button and changes at runtime, so
        -- the click reads it through the closure.
        local b
        b = MakeGroupButton(f, "", w, function() StartPull(b.secs) end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (w + ROW_GAP) * (i - 1), y)
        pullButtons[i] = b
    end
    local cancel = MakeGroupButton(f, "Stop", w, StopPull)
    cancel:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (w + ROW_GAP) * PULL_SLOTS, y)
    y = y - ROW_H

    f:SetHeight(-y)
end

-- Row order matches how they are used: unit markers first, ground markers
-- under them. Labels reach L as variables (see the SECTIONS comment).
local MARKER_ROWS = {
    { kind = "target", label = "Target" },
    { kind = "world",  label = "World"  },
}

-- The dim caption that names a row inside a holder. Shared by the marker rows
-- and the raid group row so the two cannot style differently; returns the
-- fontstring, because one caller keeps writing to it.
local function MakeRowLabel(f, y)
    local lbl = TrackFont(f, EllesmereUI.MakeFont(f, 9, nil, 1, 1, 1), 9)
    lbl:SetAlpha(0.55)
    lbl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    return lbl
end

local function BuildMarkersContent()
    holders.Markers = CreateFrame("Frame", nil, sections.Markers)
    holders.Markers:SetWidth(PANEL_W)
    fontOwners[#fontOwners + 1] = holders.Markers
    local f = holders.Markers
    local y = 0

    -- 8 markers + a clear button per row, evenly spread across the width.
    local step = (PANEL_W - PAD * 2 - MARKER_SZ) / 8
    for r, row in ipairs(MARKER_ROWS) do
        MakeRowLabel(f, y):SetText(EllesmereUI.L(row.label))
        y = y - MARKER_LBL_H - 2

        for i = 0, 8 do
            local b = MakeMarkerButton(f, i == 8 and 0 or (i + 1), row.kind)
            b:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + step * i, y)
        end
        y = y - MARKER_SZ
        if r < #MARKER_ROWS then y = y - ROW_GAP * 2 end
    end

    f:SetHeight(-y)
end

-- Raid Groups content: one row of eight numbered toggles, sharing the panel
-- width the way the pull row does. The sub-label matters most in combined
-- mode, where a bare row of numerals under two marker rows would read as
-- nothing in particular.
local function BuildRaidGroupsContent()
    holders.RaidGroups = CreateFrame("Frame", nil, sections.RaidGroups)
    holders.RaidGroups:SetWidth(PANEL_W)
    fontOwners[#fontOwners + 1] = holders.RaidGroups
    local f = holders.RaidGroups
    local y = 0

    -- Text is RefreshRaidGroups's to own -- it doubles as the no-raid-frames
    -- explanation.
    raidGroupsRowLabel = MakeRowLabel(f, y)
    y = y - MARKER_LBL_H - 2

    local w = (PANEL_W - PAD * 2 - (RAID_GROUPS - 1) * ROW_GAP) / RAID_GROUPS
    for i = 1, RAID_GROUPS do
        local b = MakeRaidGroupButton(f, i, w)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (w + ROW_GAP) * (i - 1), y)
    end
    y = y - ROW_H

    f:SetHeight(-y)
end

-- The collapsed-state square: bg + border + the icon, expanding on click.
-- A click template (not a state template) -- it cannot dispatch _onstate, so
-- the shells fan the driver verdict to it (see MakeShell).
local function BuildCollapsedIcon()
    iconBtn = CreateFrame("Button", "EllesmereUIRaidToolsIcon", UIParent,
                          "SecureHandlerClickTemplate")
    iconBtn:SetSize(ICON_SZ, ICON_SZ)
    iconBtn:SetFrameStrata("MEDIUM")
    iconBtn:SetClampedToScreen(true)
    iconBtn:RegisterForClicks("AnyDown")
    iconBtn:Hide()
    -- Rides the Group shell's saved position with no bookkeeping of its own:
    -- anchoring to a hidden frame is fine, the anchor resolves through its
    -- points.
    iconBtn:SetPoint("TOPLEFT", nil, "TOPLEFT", 0, 0)  -- re-pointed at build

    -- The button IS the art: full-bleed image at full opacity, no chrome and
    -- no tooltip.
    local tex = iconBtn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints(iconBtn)
    tex:SetTexture(COLLAPSED_ICON_TEX)

    -- Hover whitens the art by 10%: the SAME image additively at 0.1 on the
    -- native HIGHLIGHT layer (auto shown on mouseover, no scripts). Re-using
    -- the image keeps the lift inside its alpha channel -- a plain white ADD
    -- rect would glow the transparent corners too. Vertex color cannot do
    -- this; it only multiplies downward.
    local hl = iconBtn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(iconBtn)
    hl:SetTexture(COLLAPSED_ICON_TEX)
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.5)

    iconBtn:SetAttribute("enabled", true)
    iconBtn:SetAttribute("visible", false)
    iconBtn:SetAttribute("override", "")
    iconBtn:SetAttribute("expanded", true)
    iconBtn:SetAttribute("startexpanded", true)
    iconBtn:SetAttribute("apply", [[
        if not self:GetAttribute("enabled") then
            self:Hide()
            return
        end
        local ov = self:GetAttribute("override")
        local vis
        if ov == "show" then
            vis = true
        elseif ov == "hide" then
            vis = false
        else
            vis = self:GetAttribute("visible")
        end
        if vis and not self:GetAttribute("expanded") then
            self:Show()
        else
            self:Hide()
        end
    ]])
    iconBtn:SetAttribute("_onclick", EXPAND_SNIPPET)
end

local function BuildAll()
    if sections.Group then return end
    for _, key in ipairs(SECTION_KEYS) do MakeShell(key) end
    BuildGroupContent()
    BuildMarkersContent()
    BuildRaidGroupsContent()
    BuildCollapsedIcon()
    -- Re-anchored by ApplyLayout to whichever shell is primary; this only has
    -- to be a resolvable anchor before the first layout pass.
    iconBtn:ClearAllPoints()
    iconBtn:SetPoint("TOPLEFT", sections.Group, "TOPLEFT", 0, 0)

    -- Keybind target. Shown (a hidden button cannot take a CLICK binding) but
    -- 1px, transparent and parked off-screen. It flips everything together
    -- from one computed value, so the pieces can never drift apart.
    toggleButton = CreateFrame("Button", "EllesmereUIRaidToolsToggle", UIParent,
                               "SecureHandlerClickTemplate")
    toggleButton:SetSize(1, 1)
    toggleButton:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -100, -100)
    toggleButton:SetAlpha(0)
    toggleButton:RegisterForClicks("AnyDown")
    toggleButton:SetAttribute("count", #SECTION_KEYS)
    toggleButton:SetAttribute("_onclick", TOGGLE_SNIPPET)

    -- Frame refs: the toggle, the icon and each collapse button all reach the
    -- same set; the shells reach the icon for the _onstate fan-out.
    for i, key in ipairs(SECTION_KEYS) do
        local shell = sections[key]
        toggleButton:SetFrameRef("s" .. i, shell)
        shell:SetFrameRef("icon", iconBtn)
        shell._collapseBtn:SetAttribute("count", #SECTION_KEYS)
        for j, k2 in ipairs(SECTION_KEYS) do
            shell._collapseBtn:SetFrameRef("s" .. j, sections[k2])
        end
        shell._collapseBtn:SetFrameRef("icon", iconBtn)
        iconBtn:SetFrameRef("s" .. i, shell)
    end
    toggleButton:SetFrameRef("icon", iconBtn)
    iconBtn:SetAttribute("count", #SECTION_KEYS)
end

-------------------------------------------------------------------------------
--  Layout / position / mode
-------------------------------------------------------------------------------

-- Show-as arrangement. OOC only (Apply gates); the holders are plain frames,
-- so the re-parent is an ordinary SetParent.
local function ApplyLayout()
    local p = P()
    local combined = Combined()
    local primary = PrimaryWindow()

    -- One collapse control, on the primary window: it folds the whole feature,
    -- so a second on any other shell would be a duplicate.
    local collapseUI = p and p.collapsedIcon ~= false
    for _, key in ipairs(SECTION_KEYS) do
        sections[key]._collapseBtn:SetShown(collapseUI and key == primary)
    end

    if combined then
        local host = sections[primary]
        local y, shown = CONTENT_TOP, 0
        for _, key in ipairs(SECTION_KEYS) do
            local hold = holders[key]
            if WindowOn(key) then
                shown = shown + 1
                hold:SetShown(true)
                hold:SetParent(host)
                hold:ClearAllPoints()
                hold:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
                y = y + hold:GetHeight() + ROW_GAP * 2
            else
                -- Left parented where it was: a hidden holder anchors nothing
                -- and costs nothing, and re-parenting it would be work with no
                -- observable effect.
                hold:SetShown(false)
            end
        end
        -- The last group added a trailing gap that no content follows.
        host:SetHeight(y - ROW_GAP * 2 + PAD)
        -- "Raid Tools" only when the window actually carries more than one
        -- content group; a single one keeps its own name.
        shellTitle[primary]:SetText(EllesmereUI.L(
            (shown > 1) and COMBINED_LABEL or SECTION_LABEL[primary]))
    else
        -- Each holder returns to its own shell; which shells actually SHOW is
        -- ApplyVisibility's call (the enabled attribute).
        for _, key in ipairs(SECTION_KEYS) do
            local shell, hold = sections[key], holders[key]
            shellTitle[key]:SetText(EllesmereUI.L(SECTION_LABEL[key]))
            hold:SetParent(shell)
            hold:SetShown(true)
            hold:ClearAllPoints()
            hold:SetPoint("TOPLEFT", shell, "TOPLEFT", 0, -CONTENT_TOP)
            shell:SetHeight(CONTENT_TOP + hold:GetHeight() + PAD)
        end
    end

    -- The collapsed icon rides the shell that is actually on screen.
    iconBtn:ClearAllPoints()
    iconBtn:SetPoint("TOPLEFT", sections[primary], "TOPLEFT", 0, 0)

    -- Heights just moved: re-crop the backdrop art so it covers instead of
    -- stretches (the skins hook SetHeight for this; our heights only ever
    -- change right here, so a direct call is the whole hook).
    for _, key in ipairs(SECTION_KEYS) do
        local shell = sections[key]
        if shell._bgFit then shell._bgFit() end
    end
end

-- Positions round-trip through unlock mode's CENTER/CENTER convention.
--
-- That pairing is not decoration: for an odd-height frame the stored centre
-- ends in .5, and ApplyCenterPosition subtracts the live half-height so the
-- edges land back on whole pixels. Applying the stored value with a plain
-- SetPoint skips that and leaves the frame a pixel off -- visible only after
-- the snap tool, because a normal drag is converted on the way in and a
-- snapped one is not.
local function DefaultPos(key)
    -- Unpositioned installs park the whole feature in the TOP-LEFT corner of
    -- the screen (a small margin off the edges); two-window mode stacks
    -- Markers under Group & Pull. A saved position always wins over this.
    local MARGIN = 20
    local top = -MARGIN
    for _, k in ipairs(SECTION_KEYS) do
        if k == key then break end
        if ShellActive(k) then
            top = top - (sections[k]:GetHeight() * WindowScale() + ROW_GAP)
        end
    end
    -- Screen-space margin converted into the frame's own scaled units.
    local s = WindowScale()
    return { point = "TOPLEFT", relPoint = "TOPLEFT", x = MARGIN / s, y = top / s }
end

local function ApplySectionPosition(key)
    local f = sections[key]
    if not f then return end
    if InCombatLockdown() then applyPending = true; return end

    local pos = ((P() and P().pos) or {})[key] or DefaultPos(key)
    if EllesmereUI.ApplyCenterPosition
       and pos.point == "CENTER" and pos.relPoint == "CENTER" then
        -- Skips anchor-linked elements itself, and defers its own combat case
        -- for protected frames. FALSE means it could not resolve a live frame
        -- for this key -- fall through to the plain path, exactly as unlock
        -- mode's own caller does.
        if EllesmereUI.ApplyCenterPosition(UNLOCK_KEY .. key, pos) then return end
    end

    -- Anything not in that convention is a default or a pre-conversion value.
    if EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored(UNLOCK_KEY .. key) then
        return
    end
    f:ClearAllPoints()
    f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
end

local function ApplyPositions()
    -- While an unlock session is open UNLOCK MODE owns these frames: it moves
    -- them live and only writes the result on Save & Exit. A settings pass
    -- landing mid-session (the options panel hiding/showing flips the preview,
    -- and a combat-deferred Apply completes on PLAYER_REGEN_ENABLED) would drag
    -- the window back to the last SAVED spot -- and because Save & Exit derives
    -- the value it stores from the frame's LIVE bounds, the drag is then
    -- written back as the old position and lost for good. Same guard Action
    -- Bars, Aura Reminders and the Cooldown Manager already carry.
    if EllesmereUI._unlockActive then return end

    -- Only the shells that can be on screen: combined mode positions the
    -- primary alone (everything rides its pos), split mode positions each
    -- checked window from its own.
    for _, key in ipairs(SECTION_KEYS) do
        if ShellActive(key) then ApplySectionPosition(key) end
    end
end

-- The whole replacement for the old shared-visibility machinery: two literal
-- driver strings keyed by mode. [group] is any group; [group:raid] raid only.
local MODE_DRIVERS = {
    raid  = "[group:raid] show; hide",
    group = "[group] show; hide",
}

-- Reached only from Apply, which has already returned if we are in combat.
local function ApplyVisibility()
    local p = P()
    local mode = Mode()
    local driver = MODE_DRIVERS[mode]
    -- The out-of-combat settle for the state a driver will not re-fire
    -- (registering one only fires _onstate on a CHANGE). Always mode has no
    -- driver at all: the settle IS its entire visibility source.
    local visNow = false
    if mode == "raid" then
        visNow = IsInRaid()
    elseif mode == "group" then
        visNow = IsInGroup()
    elseif mode == "always" then
        visNow = true
    end

    -- One seed for every show (see header): Default to Collapsed When Shown.
    -- With the toggle off the seed is "expanded" and the icon never shows.
    local startExpanded = not (p and p.collapsedIcon ~= false)

    -- Settings preview (the TBB-placeholder arrangement): while the Raid
    -- Tools page is in front, the windows are forced shown and FULLY EXPANDED
    -- so every settings change is visible as it lands, and the drivers stay
    -- unregistered so a group transition cannot collapse or hide the thing
    -- being configured mid-edit. Only the LIVE state is forced; the seeds
    -- keep their configured values for when the preview ends.
    local expandedNow = startExpanded
    if previewOn then
        driver = nil
        visNow = true
        expandedNow = true
    end

    for _, key in ipairs(SECTION_KEYS) do
        local f = sections[key]
        -- Combined mode puts everything in the primary's shell, so only that
        -- one exists on screen; split mode gives one per checked window.
        local on = ShellActive(key)

        f:SetAttribute("enabled", on)
        f:SetAttribute("visible", visNow)
        f:SetAttribute("override", "")
        f:SetAttribute("startexpanded", startExpanded)
        f:SetAttribute("expanded", expandedNow)

        UnregisterStateDriver(f, "euirt_vis")
        if on and driver then
            RegisterStateDriver(f, "euirt_vis", driver)
        end
    end

    -- The icon represents the whole feature; every Show as choice shows
    -- something, so it is simply on while the mode is active.
    iconBtn:SetAttribute("enabled", true)
    iconBtn:SetAttribute("visible", visNow)
    iconBtn:SetAttribute("override", "")
    iconBtn:SetAttribute("startexpanded", startExpanded)
    iconBtn:SetAttribute("expanded", expandedNow)

    -- Run the snippets rather than re-deciding in Lua: attributes are set
    -- first so "apply" sees them.
    if SecureHandlerExecute then
        for _, key in ipairs(SECTION_KEYS) do
            SecureHandlerExecute(sections[key], RUN_APPLY)
        end
        SecureHandlerExecute(iconBtn, RUN_APPLY)
    end
end

-- Toggle Raid Tools key: profile-stored, applied as an override binding on
-- the secure toggle button -- the exact arrangement Action Bars uses for
-- Toggle Action Bar Visibility. Pressing the bound key is a hardware click,
-- so the toggle itself works IN combat; only (re)binding defers.
local function ApplyToggleKeybind()
    if not toggleButton then return end
    ClearOverrideBindings(toggleButton)
    local p = P()
    local k = p and p.toggleKey
    if k and k ~= "" and Mode() ~= "never" then
        SetOverrideBindingClick(toggleButton, false, k, "EllesmereUIRaidToolsToggle")
    end
end

-------------------------------------------------------------------------------
--  Lifecycle
--
--  Nothing exists until the mode first leaves "never": no frames, no events,
--  no bindings, no unlock rows. Apply() is the single entry point.
-------------------------------------------------------------------------------

-- Events live only while the feature is active (or while a combat-deferred
-- Apply is pending, since PLAYER_REGEN_ENABLED is what completes it). The
-- frame itself is created on first need and reused.
local ev
local function EnsureEvents()
    if not ev then
        ev = CreateFrame("Frame")
        ev:SetScript("OnEvent", function(_, event)
            -- Pending work FIRST, before the mode gate: a switch TO "never"
            -- deferred by combat must complete even though the profile
            -- already reads never -- swallowing it here is how panels get
            -- stranded on screen.
            -- A group-filter click during combat wrote the setting but could
            -- not rebuild the raid frames. Runs before the Apply branch, which
            -- returns without reaching it.
            if event == "PLAYER_REGEN_ENABLED" and groupsPending then
                groupsPending = false
                if _G._ERF_RefreshAll then _G._ERF_RefreshAll() end
            end
            if event == "PLAYER_REGEN_ENABLED" and applyPending then
                Apply()
                return
            end
            if Mode() == "never" then return end
            RefreshPermissions()
            RefreshRaidGroups()
        end)
    end
    ev:RegisterEvent("GROUP_ROSTER_UPDATE")
    ev:RegisterEvent("PARTY_LEADER_CHANGED")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
end
local function DropEvents()
    if ev then ev:UnregisterAllEvents() end
end

-- Unlock-mode movers, registered once, on first activation. getFrame
-- returning nil keeps an element out of unlock mode, which is also how
-- one-window mode collapses the feature to a single element: the Markers
-- entry vanishes and the Group entry moves the combined window via pos.Group.
local unlockRegistered
local function RegisterUnlock()
    if unlockRegistered then return end
    local MK = EllesmereUI.MakeUnlockElement
    if not MK then return end
    unlockRegistered = true

    local elements = {}
    for i, key in ipairs(SECTION_KEYS) do
        elements[#elements + 1] = MK({
            key      = UNLOCK_KEY .. key,
            label    = SECTION_LABEL[key],
            group    = "Raid Tools",
            order    = 540 + i,
            noResize = true,
            getFrame = function()
                if Mode() == "never" then return nil end
                -- Offer exactly the shells that are on screen: combined mode
                -- collapses to the primary element alone, split mode gives one
                -- per checked window.
                if not ShellActive(key) then return nil end
                BuildAll()
                return sections[key]
            end,
            getSize  = function()
                -- Unlock mode sizes the mover overlay in UIParent units, so
                -- the Window Scale has to be folded in here -- GetWidth is the
                -- frame's own (unscaled) size.
                local s = WindowScale()
                local f = sections[key]
                if f then return f:GetWidth() * s, f:GetHeight() * s end
                return PANEL_W * s, 60 * s
            end,
            savePos = function(_, point, relPoint, x, y)
                if not point then return end
                local p = P(); if not p then return end
                -- Unlock mode hands us two conventions: a normal drag arrives
                -- already converted to CENTER/CENTER, a snapped one arrives
                -- raw. Converting here makes both identical --
                -- ConvertToCenterPos passes an already-CENTER value through
                -- untouched, so the drag path is unaffected.
                if EllesmereUI.ConvertToCenterPos then
                    point, relPoint, x, y =
                        EllesmereUI.ConvertToCenterPos(UNLOCK_KEY .. key, point, relPoint, x, y)
                end
                -- Direct index, no `p.pos = p.pos or {}` reseed: DB_DEFAULTS
                -- guarantees the table, and under a Spec Overrides capture
                -- proxy the reseed stores a proxy into the real profile (the
                -- hazard the P() comment documents). Writing THROUGH p.pos is
                -- proxy-safe; storing it back is not.
                if not p.pos then return end
                p.pos[key] = { point = point, relPoint = relPoint, x = x, y = y }
                if not EllesmereUI._unlockActive then ApplySectionPosition(key) end
            end,
            loadPos  = function() return ((P() and P().pos) or {})[key] end,
            clearPos = function()
                local p = P(); if p and p.pos then p.pos[key] = nil end
            end,
            applyPos = function() ApplySectionPosition(key) end,
        })
    end
    if #elements > 0 then
        EllesmereUI:RegisterUnlockElements(elements, "EllesmereUIQoL")
    end
end

-- Options-page entry point, and the completion target for combat-deferred
-- work. Every path below writes secure attributes, drivers, bindings or
-- geometry on protected frames -- ALL blocked in lockdown, the switch to
-- "never" included (SetAttribute is as protected as Hide). So in combat the
-- whole request is parked behind applyPending, with the REGEN listener
-- guaranteed alive to finish it.
function Apply()
    if InCombatLockdown() then
        applyPending = true
        EnsureEvents()
        return
    end
    applyPending = false

    -- The settings preview builds and shows even on Never: the page being in
    -- front means the user is configuring the thing, and an invisible subject
    -- makes every control feel dead. Preview off restores the true teardown.
    if Mode() == "never" and not previewOn then
        if sections.Group then
            for _, key in ipairs(SECTION_KEYS) do
                local f = sections[key]
                UnregisterStateDriver(f, "euirt_vis")
                f:SetAttribute("enabled", false)
                f:SetAttribute("override", "")
                f:Hide()
            end
            iconBtn:SetAttribute("enabled", false)
            iconBtn:Hide()
            ClearOverrideBindings(toggleButton)
        end
        -- Fully off and nothing pending: no reason to keep hearing roster
        -- spam. Never-activated sessions never created the frame at all.
        DropEvents()
        return
    end

    EnsureEvents()
    RegisterUnlock()
    BuildAll()
    ApplyLayout()
    -- One Window Scale for everything the feature draws.
    local scale = WindowScale()
    for _, key in ipairs(SECTION_KEYS) do sections[key]:SetScale(scale) end
    iconBtn:SetScale(scale)
    ApplyPositions()
    ApplyVisibility()
    ApplyToggleKeybind()
    ApplyFonts()
    RefreshPullTimes()
    RefreshPermissions(true)
    RefreshRaidGroups(true)
end
_G._EUI_RaidTools_Apply = Apply

-- Settings-page preview switch (see ApplyVisibility). A global rather than an
-- ns export on purpose: the QoL page dispatcher in EUI_QoL_Options.lua has no
-- ns capture, and it is the one that must end the preview when another QoL
-- page builds. Same convention as _EUI_RaidTools_Apply.
_G._EUI_RaidTools_Preview = function(on)
    on = on and true or false
    if previewOn == on then return end
    previewOn = on
    Apply()
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------

-- Same snippet as the keybind, entered through SecureHandlerExecute -- which
-- insecure code may only do out of combat, hence the message below. This
-- deliberately does NOT go through toggleButton:Click(): the button is
-- registered for "AnyDown" only, and a bare Click() simulates an up event, so
-- the handler would never fire. The keybind keeps the hardware path because a
-- real click is the only thing that can run the snippet during combat.
local function ToggleOutOfCombat()
    if toggleButton and SecureHandlerExecute then
        SecureHandlerExecute(toggleButton, TOGGLE_SNIPPET)
    end
end

SLASH_EUIRAIDTOOLS1 = "/euiraid"
SlashCmdList["EUIRAIDTOOLS"] = function()
    if Mode() == "never" then
        EllesmereUI.Print("|cff0cd29fEllesmereUI:|r " .. EllesmereUI.L("Raid Tools is disabled in the EllesmereUI options."))
        return
    end
    if InCombatLockdown() then
        EllesmereUI.Print("|cff0cd29fEllesmereUI:|r " .. EllesmereUI.L("Raid Tools cannot be toggled by slash command in combat -- use the keybind."))
        return
    end
    BuildAll()
    ToggleOutOfCombat()
end

-------------------------------------------------------------------------------
--  Init -- same shape as the other QoL features: take the shared QoL DB handle
--  on PLAYER_LOGIN, publish it, then start. Apply() is a no-op for anyone on
--  the default "never" mode: no frames, no events, no unlock rows.
-------------------------------------------------------------------------------
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if not (EllesmereUI and EllesmereUI.Lite and EllesmereUI.Lite.NewDB) then return end
    db = EllesmereUI.Lite.NewDB("EllesmereUIQoLDB", DB_DEFAULTS, true)
    _G._EUI_RaidTools_DB = function() return db end
    Apply()
end)
