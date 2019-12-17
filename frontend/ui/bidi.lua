--[[--
Bidirectional text and UI mirroring setup and helpers.

There are 2 concepts we attempt to handle:
- Text direction: Left-To-Right (LTR) or Right-To-Left (RTL)
- UI elements mirroring: not-mirrored, or mirrored

These 2 concepts are somehow orthogonal to each other in
their implementation, even if in the real world there are
only 2 valid combinations:
- LTR and not-mirrored: for western languages, CJK, Indic...
- RTL and mirrored: for Arabic, Hebrew, Farsi and a few others.

Text direction is handled by the libkoreader-xtext.so C module,
and the TextWidget and TextBoxWidget widgets that handle text
aligment. We just need here to set the default global paragraph
direction (that widgets can override if needed).

UI mirroring is to be handled by our widget themselves, with the
help of a few functions defined here.

Fortunately, low level widgets like LeftContainer, RightContainer,
FrameContainer, HorizontalGroup, OverlapGroup... will do most of
the work.
But some care must be taken in other widgets and apps when:
- some arrow symbols are used (for next, previous, first, last...):
  they might need to be swapped, or some alternative symbols or
  images can be used.
- some geometry arithmetic is done (e.g. detecting if a tap is on the
  right part of screen, to go forward), which need to be adapted/reversed.
- handling left or right swipe, whose action might need to be reversed
- some TextBoxWidget/InputText might need to be forced to be LTR (when
  showing HTML or CSS code, or entering URLs, path...)

Some overview at:
https://material.io/design/usability/bidirectionality.html
]]

local Language = require("ui/language")
local util = require("util")
local _ = require("gettext")

local Bidi = {
    _mirrored_ui_layout = false,
    _rtl_ui_text = false,
}

-- Setup UI mirroring and RTL text for UI language
function Bidi.setup(lang)
    local is_rtl = Language:isLanguageRTL(lang)
    -- Mirror UI if language is RTL
    Bidi._mirrored_ui_layout = is_rtl
    -- Unless requested not to (or requested mirroring with LTR language)
    if G_reader_settings:isTrue("dev_reverse_ui_layout_mirroring") then
        Bidi._mirrored_ui_layout = not Bidi._mirrored_ui_layout
    end
    -- Xtext default language and direction
    if G_reader_settings:nilOrTrue("use_xtext") then
        local xtext = require("libs/libkoreader-xtext")

        -- Text direction should normally not follow ui mirroring
        -- lang override (so that Arabic is still right aligned
        -- when one wants the UI layout LTR). But allow it to
        -- be independantly reversed (for testing UI mirroring
        -- with english text right aligned).
        if G_reader_settings:isTrue("dev_reverse_ui_text_direction") then
            is_rtl = not is_rtl
        end
        Bidi._rtl_ui_text = is_rtl
        xtext.setDefaultParaDirection(is_rtl)

        -- Text language: this helps picking localized glyphs from the
        -- font (eg. ideographs shaped differently for Japanese vs
        -- Simplified Chinese vs Traditional Chinese).
        -- Allow overriding xtext language rules from main UI language
        -- (eg. English UI, with French line breaking rules)
        local alt_lang = G_reader_settings:readSetting("xtext_alt_lang") or lang
        if alt_lang then
            xtext.setDefaultLang(alt_lang)
        end
    end
    -- Optimise some wrappers by aliasing them to the right wrappers
    if Bidi._rtl_ui_text then
        Bidi.default = Bidi.rtl
        Bidi.wrap = Bidi.rtl
        Bidi.filename = Bidi._filename_rtl
        Bidi.filepath = Bidi.ltr -- see if we need to split and _filename_rtl() the filename part
        Bidi.directory = Bidi.ltr
        Bidi.dirpath = Bidi.ltr
        Bidi.path = Bidi.ltr
        Bidi.url = Bidi.ltr
    else
        Bidi.default = Bidi.ltr
        Bidi.wrap = Bidi.nowrap
        Bidi.filename = Bidi.nowrap
        Bidi.filepath = Bidi.nowrap
        Bidi.directory = Bidi.nowrap
        Bidi.dirpath = Bidi.nowrap
        Bidi.path = Bidi.nowrap
        Bidi.url = Bidi.nowrap
    end
end


-- Use this function in widgets to check if UI elements mirroring
-- is to be done
function Bidi.mirroredUILayout()
    return Bidi._mirrored_ui_layout
end

-- This function might only be useful in some rare cases (RTL text
-- is handled directly by TextWidget and TextBoxWidget)
function Bidi.rtlUIText()
    return Bidi._rtl_ui_text
end

-- Small helper to mirror gesture directions
local mirrored_directions = {
    east = "west",
    west = "east",
    northeast = "northwest",
    northwest = "northeast",
    southeast = "southwest",
    southwest = "southeast",
}

function Bidi.flipDirectionIfMirroredUILayout(direction)
    if Bidi._mirrored_ui_layout then
        return mirrored_directions[direction] or direction
    end
    return direction
end

function Bidi.flipIfMirroredUILayout(bool)
    if Bidi._mirrored_ui_layout then
        return not bool
    end
    return bool
end

-- Wrap provided text with bidirectionality control characters, see:
--   http://unicode.org/reports/tr9/#Markup_And_Formatting
--   https://www.w3.org/International/questions/qa-bidi-unicode-controls.en
--   https://www.w3.org/International/articles/inline-bidi-markup/
-- This works only when use_xtext=true: these characters are used
-- by FriBidi for correct char visual ordering, and later stripped
-- by Harfbuzz.
-- When use_xtext=false, these characters are considered as normal
-- characters, and would be printed. Fortunately, most fonts know them
-- and provide an invisible glyph of zero-width - except FreeSans and
-- FreeSerif which provide a real glyph (a square with "LRI" inside)
-- which would be an issue and would need stripping. But as these
-- Free fonts are only used as fallback fonts, and the invisible glyphs
-- will have been found in the previous fonts, we don't need to.
local LRI = "\xE2\x81\xA6"     -- U+2066 LRI / LEFT-TO-RIGHT ISOLATE
local RLI = "\xE2\x81\xA7"     -- U+2067 RLI / RIGHT-TO-LEFT ISOLATE
local FSI = "\xE2\x81\xA8"     -- U+2068 FSI / FIRST STRONG ISOLATE
local PDI = "\xE2\x81\xA9"     -- U+2069 PDI / POP DIRECTIONAL ISOLATE

function Bidi.ltr(text)
    return string.format("%s%s%s", LRI, text, PDI)
end

function Bidi.rtl(text) -- should hardly be needed
    return string.format("%s%s%s", RLI, text, PDI)
end

function Bidi.auto(text) -- from first strong character
    return string.format("%s%s%s", FSI, text, PDI)
end

function Bidi.default(text) -- default direction
    return Bidi._rtl_ui_text and Bidi.rtl(text) or Bidi.ltr(text)
end

function Bidi.nowrap(text)
    return text
end

-- Helper for concatenated string bits of numbers an symbols (like
-- our reader footer) to keep them ordered in RTL UI (to not have
-- a letter B for battery make the whole string considered LTR).
-- Note: it will be replaced and aliased to Bidi.nowrap or Bidi.rtl
-- by Bibi.setup() as an optimisation
function Bidi.wrap(text)
    return Bidi._rtl_ui_text and Bidi.rtl(text) or text
end

-- See at having GetText_mt.__call() wrap untranslated strings in Bidi.ltr()
-- so they are fully displayed LTR.

-- Use these specific wrappers when the wrapped content type is known
-- (so we can easily switch to use rtl() if RTL readers prefer filenames
-- shown as real RTL).
-- Note: when the filename or path are standalone in a TextWidget, it's
-- better to use "para_direction_rtl = false" without any wrapping.
Bidi.filename = Bidi.nowrap  -- aliased to Bidi._filename_rtl if _rtl_ui_text
Bidi.filepath = Bidi.nowrap  -- aliased to Bidi.ltr if _rtl_ui_text
Bidi.directory = Bidi.nowrap -- aliased to Bidi.ltr if _rtl_ui_text
Bidi.dirpath = Bidi.nowrap   -- aliased to Bidi.ltr if _rtl_ui_text
Bidi.path = Bidi.nowrap      -- aliased to Bidi.ltr if _rtl_ui_text
Bidi.url = Bidi.nowrap       -- aliased to Bidi.ltr if _rtl_ui_text

function Bidi._filename_rtl(filename)
    -- We always want to show the extension either on the left
    -- or on the right - never in the middle (which could happen
    -- with the bidi algo if we give it the filename as-is).
    local name, suffix = util.splitFileNameSuffix(filename)
    -- Let the first strong character of the filename decides
    -- about the direction
    return Bidi.auto(name .. "." .. Bidi.ltr(suffix))
end

return Bidi
