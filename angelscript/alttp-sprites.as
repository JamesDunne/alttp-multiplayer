// AngelScript for ALTTP to draw white rectangles around in-game sprites
class SpritesWindow {
  private gui::Window @window;
  private gui::VerticalLayout @vl;
  gui::Canvas @canvas;

  array<uint16> fgtiles(0x2000);

  SpritesWindow() {
    // relative position to bsnes window:
    @window = gui::Window(256*2, 0, true);
    window.title = "Sprite VRAM";
    window.size = gui::Size(256, 512);

    @vl = gui::VerticalLayout();
    window.append(vl);

    @canvas = gui::Canvas();
    canvas.size = gui::Size(128, 256);
    vl.append(canvas, gui::Size(-1, -1));

    vl.resize();
    canvas.update();
    window.visible = true;
  }

  void update() {
    canvas.update();
  }

  void render(const array<uint16> &palette) {
    // read VRAM:
    ppu::vram.read_block(0x4000, 0, 0x2000, fgtiles);

    // draw VRAM as 4bpp tiles:
    sprites.canvas.fill(0x0000);
    sprites.canvas.draw_sprite_4bpp(0, 0, 0, 128, 256, fgtiles, palette);
  }
};
SpritesWindow @sprites;
array<uint16> palette7(16);

uint16   xoffs, yoffs;
uint16[] sprx(16);
uint16[] spry(16);
uint8[]  sprs(16);
uint8[]  sprk(16);
uint32   location;

uint8 module, sub_module;
// top -> $4000, bot -> $4100
array<uint16> dma10top(3), dma10bot(3);
array<uint16> dma7Etop(6), dma7Ebot(6);

uint8 sg0, sg1;

void init() {
  // initialize script state here.
  message("hello world!");
  @sprites = SpritesWindow();
}

void pre_frame() {
  module     = bus::read_u8(0x7E0010);
  sub_module = bus::read_u8(0x7E0011);

  // [$10]$0ACE -> $4100 (0x40 bytes) (bottom of head)
  // [$10]$0AD2 -> $4120 (0x40 bytes) (bottom of body)
  // [$10]$0AD6 -> $4140 (0x20 bytes) (bottom sweat/arm/hand)

  dma10bot[0] = bus::read_u16(0x7E0ACE);
  dma10bot[1] = bus::read_u16(0x7E0AD2);
  dma10bot[2] = bus::read_u16(0x7E0AD6);

  // [$10]$0ACC -> $4000 (0x40 bytes) (top of head)
  // [$10]$0AD0 -> $4020 (0x40 bytes) (top of body)
  // [$10]$0AD4 -> $4040 (0x20 bytes) (top sweat/arm/hand)

  dma10top[0] = bus::read_u16(0x7E0ACC);
  dma10top[1] = bus::read_u16(0x7E0AD0);
  dma10top[2] = bus::read_u16(0x7E0AD4);

  // bank $7E (WRAM) is used to store decompressed 3bpp->4bpp tile data
  // need to call Do3To4HighAnimated at $5619-$566D to decomp to $7E9000,X

  // [$7E]$0AC0 -> $4050 (0x40 bytes) (top of sword slash)
  // [$7E]$0AC4 -> $4070 (0x40 bytes) (top of shield)
  // [$7E]$0AC8 -> $4090 (0x40 bytes) (Zz sprites)
  // [$7E]$0AE0 -> $40B0 (0x20 bytes) (top of rupee)
  // [$7E]$0AD8 -> $40C0 (0x40 bytes) (top of movable block)

  dma7Etop[0] = bus::read_u16(0x7E0AC0);
  dma7Etop[1] = bus::read_u16(0x7E0AC4);
  dma7Etop[2] = bus::read_u16(0x7E0AC8);
  dma7Etop[3] = bus::read_u16(0x7E0AE0);
  dma7Etop[4] = bus::read_u16(0x7E0AD8);

  // only if bird is active
  // [$7E]$0AF6 -> $40E0 (0x40 bytes) (top of hammer sprites)
  dma7Etop[5] = bus::read_u16(0x7E0AF6);

  // [$7E]$0AC2 -> $4150 (0x40 bytes) (bottom of sword slash)
  // [$7E]$0AC6 -> $4170 (0x40 bytes) (bottom of shield)
  // [$7E]$0ACA -> $4190 (0x40 bytes) (music note sprites)
  // [$7E]$0AE2 -> $41B0 (0x20 bytes) (bottom of rupee)
  // [$7E]$0ADA -> $41C0 (0x40 bytes) (bottom of movable block)

  dma7Ebot[0] = bus::read_u16(0x7E0AC2);
  dma7Ebot[1] = bus::read_u16(0x7E0AC6);
  dma7Ebot[2] = bus::read_u16(0x7E0ACA);
  dma7Ebot[3] = bus::read_u16(0x7E0AE2);
  dma7Ebot[4] = bus::read_u16(0x7E0ADA);

  // only if bird is active
  // [$7E]$0AF8 -> $41E0 (0x40 bytes) (bottom of hammer sprites)
  dma7Ebot[5] = bus::read_u16(0x7E0AF8);

  // fetch various room indices and flags about where exactly Link currently is:
  auto in_dark_world  = bus::read_u8 (0x7E0FFF);
  auto in_dungeon     = bus::read_u8 (0x7E001B);
  auto overworld_room = bus::read_u16(0x7E008A);
  auto dungeon_room   = bus::read_u16(0x7E00A0);

  // compute aggregated location for Link into a single 24-bit number:
  location =
    uint32(in_dark_world & 1) << 17 |
    uint32(in_dungeon & 1) << 16 |
    uint32(in_dungeon != 0 ? dungeon_room : overworld_room);

  // get screen x,y offset by reading BG2 scroll registers:
  xoffs = bus::read_u16(0x7E00E2);
  yoffs = bus::read_u16(0x7E00E8);

  for (int i = 0; i < 16; i++) {
    // sprite x,y coords are absolute from BG2 top-left:
    spry[i] = bus::read_u16(0x7E0D00 + i);
    sprx[i] = bus::read_u16(0x7E0D10 + i);
    // sprite state (0 = dead, else alive):
    sprs[i] = bus::read_u8(0x7E0DD0 + i);
    // sprite kind:
    sprk[i] = bus::read_u8(0x7E0E20 + i);
  }

  if (sprites != null) {
    for (int i = 0; i < 16; i++) {
      palette7[i] = ppu::cgram[(15 << 4) + i];
    }
    sprites.render(palette7);
    sprites.update();
  }
}

void post_frame() {
  // set drawing state
  // select 8x8 or 8x16 font for text:
  ppu::frame.font_height = 8;
  // draw using alpha blending:
  ppu::frame.draw_op = ppu::draw_op::op_alpha;
  // alpha is xx/31:
  ppu::frame.alpha = 29;
  // color is 0x7fff aka white (15-bit RGB)
  ppu::frame.color = ppu::rgb(20, 20, 31);

  // enable shadow under text for clearer reading:
  ppu::frame.text_shadow = true;

  // module/sub_module:
  ppu::frame.text(0, 0, fmtHex(module, 2));
  ppu::frame.text(20, 0, fmtHex(sub_module, 2));

  // draw Link's location value in top-left:
  ppu::frame.text(40, 0, fmtHex(location, 6));

  for (uint i = 0; i < 3; i++) {
    ppu::frame.text(i * (4 * 8 + 4), 224 - 24, fmtHex(dma10top[i], 4));
    ppu::frame.text(i * (4 * 8 + 4), 224 - 32, fmtHex(dma10bot[i], 4));

    //ppu::frame.text(i * (4 * 8 + 4), 224 -  8, fmtHex(dma7Etop[i], 4));
    //ppu::frame.text(i * (4 * 8 + 4), 224 - 16, fmtHex(dma7Ebot[i], 4));
  }

  //for (uint i = 3; i < 6; i++) {
  //  ppu::frame.text(i * (4 * 8 + 4), 224 -  8, fmtHex(dma7Etop[i], 4));
  //  ppu::frame.text(i * (4 * 8 + 4), 224 - 16, fmtHex(dma7Ebot[i], 4));
  //}

  // not useful
  //ppu::frame.text( 0, 224 - 40, fmtHex(sg0, 2));
  //ppu::frame.text(20, 224 - 40, fmtHex(sg1, 2));

  if (false) {
    for (int i = 0; i < 16; i++) {
      // skip dead sprites:
      if (sprs[i] == 0) continue;

      // subtract BG2 offset from sprite x,y coords to get local screen coords:
      int16 rx = int16(sprx[i]) - int16(xoffs);
      int16 ry = int16(spry[i]) - int16(yoffs);

      // draw box around the sprite:
      ppu::frame.rect(rx, ry, 16, 16);

      // draw sprite type value above box:
      ry -= ppu::frame.font_height;
      ppu::frame.text(rx, ry, fmtHex(sprk[i], 2));
    }
  }
}
