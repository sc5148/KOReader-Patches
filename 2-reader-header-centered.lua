--[[
    This user patch adds a "header" into the reader display, similar to the footer at the bottom.

    It is a combination of joshuacant's "centered" and "cornered" header patches:
    it draws THREE items - one in the upper left corner, one truly centered, and one in the
    upper right corner - with a small padding between the text and the top edge.

    As configured below: book title on the left, clock in the centre, chapter name on the right.

    It is only drawn for "reflowable" documents like EPUB, not for "fixed layout" documents
    like PDF and CBZ.

    It is up to you to provide enough of a top margin so that your book contents are not
    obscured by the header. You'll know right away if you need to increase the top margin.

    Original patches:
    https://github.com/joshuacant/KOReader.patches
    Reference for anything else you might want to display:
    https://github.com/koreader/koreader/blob/master/frontend/apps/reader/modules/readerfooter.lua
--]]

local Blitbuffer = require("ffi/blitbuffer")
local FontChooser = require("ui/widget/fontchooser")
local TextWidget = require("ui/widget/textwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local BD = require("ui/bidi")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Device = require("device")
local Font = require("ui/font")
local logger = require("logger")
local util = require("util")
local datetime = require("datetime")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template
local ReaderView = require("apps/reader/modules/readerview")
local _ReaderView_paintTo_orig = ReaderView.paintTo
local header_settings = G_reader_settings:readSetting("footer") or {}
local screen_width = Screen:getWidth()

-- ===========================!!!!!!!!!!!!!!!=========================== -
-- Set to false if you do not want the clock to tick on its own.
-- When true, the header strip is repainted once a minute (see notes at the bottom).
local header_auto_refresh = true
-- ===========================!!!!!!!!!!!!!!!=========================== -

local header_view    -- the ReaderView we last drew a header for
local header_region  -- the screen area the header occupies

local function autoRefreshHeader()
    UIManager:unschedule(autoRefreshHeader)
    local view = header_view
    if not view or not view.dialog then return end
    -- Don't repaint if a menu/dialog is on top; just try again next minute
    local top_wg = UIManager:getTopmostVisibleWidget() or {}
    if top_wg.name ~= "ReaderUI" then
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), autoRefreshHeader)
        return
    end
    -- "ui" = non-flashing update, restricted to the header strip
    UIManager:setDirty(view.dialog, "ui", header_region)
    -- the resulting repaint calls paintTo again, which schedules the next tick
end

-- Stop the timer when the document is closed
local _ReaderView_onCloseWidget_orig = ReaderView.onCloseWidget
ReaderView.onCloseWidget = function(self)
    UIManager:unschedule(autoRefreshHeader)
    header_view = nil
    return _ReaderView_onCloseWidget_orig(self)
end

ReaderView.paintTo = function(self, bb, x, y)
    _ReaderView_paintTo_orig(self, bb, x, y)
    if self.render_mode ~= nil then return end -- Show only for epub-likes and never on pdf-likes
    if bb ~= Screen.bb then return end -- Only draw on the real screen; skip off-screen renders (page browser / book map thumbnails), otherwise their thumbnails never load
    -- don't change anything above this line



    -- ===========================!!!!!!!!!!!!!!!=========================== -
    -- Configure formatting options for header here, if desired
    -- local header_font_face = "ffont" -- this is the same font the footer uses
    -- Follow the footer's font, falling back to the footer's own default
    local header_font_face = header_settings.text_font_face or "./fonts/noto/NotoSans-Regular.ttf"
    if not FontChooser.isFontRegistered(header_font_face) then
        header_font_face = "./fonts/noto/NotoSans-Regular.ttf"
    end
    -- header_font_face = "source/SourceSerif4-Regular.ttf" -- this is the serif font from Project: Title
    local header_font_size = header_settings.text_font_size or 14 -- Will use your footer setting if available
    local header_font_bold = header_settings.text_font_bold or false -- Will use your footer setting if available
    local header_font_color = Blitbuffer.COLOR_BLACK -- black is the default, but there's 15 other shades to try
    local header_top_padding = Size.padding.default -- replace small with default or large for more space at the top
    local header_use_book_margins = true -- Use same margins as book for header
    local header_margin = Size.padding.large -- Use this instead, if book margins is set to false
    local center_max_width_pct = 25 -- how much space the CENTRE item may use before "truncating..."
    local header_gap = Size.padding.large -- minimum blank space between centre item and each corner
    local separator = {
        bar     = "|",
        bullet  = "•",
        dot     = "·",
        em_dash = "—",
        en_dash = "-",
    }
    -- ===========================!!!!!!!!!!!!!!!=========================== -



    -- You probably don't need to change anything in the section below this line
    -- Title and Author(s):
    local book_title = ""
    local book_author = ""
    if self.ui.doc_props then
        book_title = self.ui.doc_props.display_title or ""
        book_author = self.ui.doc_props.authors or ""
        if book_author:find("\n") then -- Show first author if multiple authors
            book_author =  T(_("%1 et al."), util.splitToArray(book_author, "\n")[1] .. ",")
        end
    end
    -- Page count and percentage
    local pageno = self.state.page or 1 -- Current page
    local pages = self.ui.doc_settings.data.doc_pages or 1
    local page_progress = ("%d / %d"):format(pageno, pages)
    local pages_left_book  = pages - pageno
    local percentage = (pageno / pages) * 100 -- Format like %.1f in the header strings below
    -- Chapter Info
    local book_chapter = ""
    local pages_chapter = 0
    local pages_left = 0
    local pages_done = 0
    if self.ui.toc then
        book_chapter = self.ui.toc:getTocTitleByPage(pageno) or "" -- Chapter name
        pages_chapter = self.ui.toc:getChapterPageCount(pageno) or pages
        pages_left = self.ui.toc:getChapterPagesLeft(pageno) or self.ui.document:getTotalPagesLeft(pageno)
        pages_done = self.ui.toc:getChapterPagesDone(pageno) or 0
    end
    pages_done = pages_done + 1 -- This +1 is to include the page you're looking at
    local chapter_progress = pages_done .. " ⁄⁄ " .. pages_chapter
    -- Clock:
    local time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")) or ""
    -- Battery:
    local battery = ""
    if Device:hasBattery() then
        local power_dev = Device:getPowerDevice()
        local batt_lvl = power_dev:getCapacity() or 0
        local is_charging = power_dev:isCharging() or false
        local batt_prefix = power_dev:getBatterySymbol(power_dev:isCharged(), is_charging, batt_lvl) or ""
        battery = batt_prefix .. batt_lvl .. "%"
    end
    -- You probably don't need to change anything in the section above this line



    -- ===========================!!!!!!!!!!!!!!!=========================== -
    -- What you put here will show in the header:
    local left_corner_header  = book_chapter
    local center_header       = time
    local right_corner_header = string.format("%d of %d", pageno, pages)
    -- Look up "string.format" in Lua if you want to combine several values in one slot.
    -- ===========================!!!!!!!!!!!!!!!=========================== -



    -- don't change anything below this line
    local left_margin = header_margin
    local right_margin = header_margin
    if header_use_book_margins then -- Set width based on R + L margins
        left_margin = self.document:getPageMargins().left or header_margin
        right_margin = self.document:getPageMargins().right or header_margin
    end
    local margins = left_margin + right_margin
    local avail_width = screen_width - margins -- deduct margins from width

    local header_face = Font:getFace(header_font_face, header_font_size)

    -- max_width is in PIXELS here (the original patches used a percentage)
    local function getFittedText(text, max_width)
        if text == nil or text == "" or max_width == nil or max_width <= 0 then
            return ""
        end
        local text_widget = TextWidget:new{
            text = text:gsub(" ", "\u{00A0}"), -- no-break-space
            max_width = max_width,
            face = header_face,
            bold = header_font_bold,
            padding = 0,
        }
        local fitted_text, add_ellipsis = text_widget:getFittedText()
        text_widget:free()
        if add_ellipsis then
            fitted_text = fitted_text .. "…"
        end
        return BD.auto(fitted_text)
    end

    local function makeTextWidget(text)
        return TextWidget:new{
            text = text,
            face = header_face,
            bold = header_font_bold,
            fgcolor = header_font_color,
            padding = 0,
        }
    end

    -- 1. Centre item first, because its width decides how much room the corners get
    local center_header_text = makeTextWidget(
        getFittedText(center_header, avail_width * center_max_width_pct * (1/100)))
    local center_w = center_header_text:getSize().w

    -- 2. Two equal side slots. Equal widths are what keep the centre item truly centred.
    local side_w = math.floor((avail_width - center_w) / 2)
    if side_w < 0 then side_w = 0 end

    -- 3. Corner items, each fitted to its slot minus a gap so they never touch the centre
    local left_header_text  = makeTextWidget(getFittedText(left_corner_header,  side_w - header_gap))
    local right_header_text = makeTextWidget(getFittedText(right_corner_header, side_w - header_gap))

    local content_h = math.max(left_header_text:getSize().h,
                               center_header_text:getSize().h,
                               right_header_text:getSize().h)
    local header_h = content_h + header_top_padding

    local header = CenterContainer:new {
        dimen = Geom:new{ w = screen_width, h = header_h },
        VerticalGroup:new {
            VerticalSpan:new { width = header_top_padding },
            HorizontalGroup:new {
                HorizontalSpan:new { width = left_margin },
                LeftContainer:new {
                    dimen = Geom:new{ w = side_w, h = content_h },
                    left_header_text,
                },
                CenterContainer:new {
                    dimen = Geom:new{ w = center_w, h = content_h },
                    center_header_text,
                },
                RightContainer:new {
                    dimen = Geom:new{ w = side_w, h = content_h },
                    right_header_text,
                },
                HorizontalSpan:new { width = right_margin },
            },
        },
    }
    header:paintTo(bb, x, y)

    if header_auto_refresh then
        header_view = self
        header_region = Geom:new{ x = x, y = y, w = screen_width, h = header_h }
        UIManager:unschedule(autoRefreshHeader)
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), autoRefreshHeader)
    end
end