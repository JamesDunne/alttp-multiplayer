
const uint MaxPacketSize = 1452;

class LocalGameState : GameState {
  array<SyncableItem@> areas(0x80);
  array<SyncableItem@> rooms(0x128);
  array<Sprite@> sprs(0x80);

  NotifyItemReceived@ itemReceivedDelegate;
  SerializeSRAMDelegate@ serializeSramDelegate;

  LocalGameState() {
    @this.itemReceivedDelegate = NotifyItemReceived(@this.collectNotifications);
    @this.serializeSramDelegate = SerializeSRAMDelegate(@this.serialize_sram);

    ancillaeOwner.resize(0x0A);
    for (uint i = 0; i < 0x0A; i++) {
      ancillaeOwner[i] = -1;
    }

    ancillae.resize(0x0A);
    for (uint i = 0; i < 0x0A; i++) {
      @ancillae[i] = @GameAncilla();
    }

    // SRAM [$000..$24f] underworld rooms:
    // create syncable item for each underworld room (word; size=2) using bitwise OR operations (type=2) to accumulate latest state:
    rooms.resize(0x128);
    for (uint a = 0; a < 0x128; a++) {
      @rooms[a] = @SyncableItem(a << 1, 2, 2);
    }

    // desync the indoor flags for the swamp palace and the watergate:
    // LDA $7EF216 : AND.b #$7F : STA $7EF216
    // LDA $7EF051 : AND.b #$FE : STA $7EF051
    @rooms[0x10B] = @SyncableItem(0x10B << 1, 2, function(uint16 oldValue, uint16 newValue) {
      return oldValue | (newValue & 0xFF7F);
    });
    @rooms[0x028] = @SyncableItem(0x028 << 1, 2, function(uint16 oldValue, uint16 newValue) {
      return oldValue | (newValue & 0xFEFF);
    });

    // SRAM [$250..$27f] unused

    // SRAM [$280..$2ff] overworld areas:
    // create syncable item for each overworld area (byte; size=1) using bitwise OR operations (type=2) to accumulate latest state:
    areas.resize(0x80);
    for (uint a = 0; a < 0x80; a++) {
      @areas[a] = @SyncableItem(0x280 + a, 1, 2);
    }

    // desync the overlay flags for the swamp palace and its light world counterpart:
    // LDA $7EF2BB : AND.b #$DF : STA $7EF2BB
    // LDA $7EF2FB : AND.b #$DF : STA $7EF2FB
    @areas[0x3B] = @SyncableItem(0x280 + 0x3B, 1, function(uint16 oldValue, uint16 newValue) {
      return oldValue | (newValue & 0xDF);
    });
    @areas[0x7B] = @SyncableItem(0x280 + 0x7B, 1, function(uint16 oldValue, uint16 newValue) {
      return oldValue | (newValue & 0xDF);
    });

    for (uint i = 0; i < 0x80; i++) {
      @sprs[i] = Sprite();
    }
  }

  bool registered = false;
  void register() {
    if (registered) return;
    if (rom is null) return;

    if (enableObjectSync) {
      cpu::register_pc_interceptor(rom.fn_sprite_init, cpu::PCInterceptCallback(this.on_object_init));
    }

    //message("tilemap intercept register");
    bus::add_write_interceptor("7e:2000-3fff", 0, bus::WriteInterceptCallback(this.tilemap_written));

    registered = true;
  }

  bool can_sample_location() const {
    switch (module) {
      // dungeon:
      case 0x07:
        // climbing/descending stairs
        if (sub_module == 0x0e) {
          // once main climb animation finishes, sample new location:
          if (sub_sub_module > 0x02) {
            return true;
          }
          // continue sampling old location:
          return false;
        }
        return true;
      case 0x09:  // overworld
        // disallow sampling during screen transition:
        if (sub_module >= 0x01 && sub_module <= 0x08) return false;
        // normal mirror is 0x23
        // mirror fail back to dark world is 0x2c
        if (sub_module == 0x23 || sub_module == 0x2c) {
          // once sub-sub module hits 3 then we are in light world
          if (sub_sub_module < 0x03) {
            return false;
          }
        }
        return true;
      case 0x0e:  // dialogs, maps etc.
        if (sub_module == 0x07) {
          // in-game mode7 map:
          return false;
        }
        return true;
      case 0x05:  // entering dungeon
      case 0x06:  // enter cave from overworld?
      case 0x0b:  // overworld master sword grove / zora waterfall
      case 0x08:  // exit cave to overworld
      case 0x0f:  // closing spotlight
      case 0x10:  // opening spotlight
      case 0x11:  // falling / fade out?
      case 0x12:  // death
      default:
        return true;
    }
    return true;
  }

  void fetch_module() {
    // 0x00 - Triforce / Zelda startup screens
    // 0x01 - File Select screen
    // 0x02 - Copy Player Mode
    // 0x03 - Erase Player Mode
    // 0x04 - Name Player Mode
    // 0x05 - Loading Game Mode
    // 0x06 - Pre Dungeon Mode
    // 0x07 - Dungeon Mode
    // 0x08 - Pre Overworld Mode
    // 0x09 - Overworld Mode
    // 0x0A - Pre Overworld Mode (special overworld)
    // 0x0B - Overworld Mode (special overworld)
    // 0x0C - ???? I think we can declare this one unused, almost with complete certainty.
    // 0x0D - Blank Screen
    // 0x0E - Text Mode/Item Screen/Map
    // 0x0F - Closing Spotlight
    // 0x10 - Opening Spotlight
    // 0x11 - Happens when you fall into a hole from the OW.
    // 0x12 - Death Mode
    // 0x13 - Boss Victory Mode (refills stats)
    // 0x14 - Attract Mode
    // 0x15 - Module for Magic Mirror
    // 0x16 - Module for refilling stats after boss.
    // 0x17 - Quitting mode (save and quit)
    // 0x18 - Ganon exits from Agahnim's body. Chase Mode.
    // 0x19 - Triforce Room scene
    // 0x1A - End sequence
    // 0x1B - Screen to select where to start from (House, sanctuary, etc.)
    module = bus::read_u8(0x7E0010);

    // when module = 0x07: dungeon
    //    sub_module = 0x00 normal gameplay in dungeon
    //               = 0x01 going through door
    //               = 0x03 triggered a star tile to change floor hole configuration
    //               = 0x05 initializing room? / locked doors?
    //               = 0x07 falling down hole in floor
    //               = 0x0e going up/down stairs
    //               = 0x0f entering dungeon first time (or from mirror)
    //               = 0x16 when orange/blue barrier blocks transition
    //               = 0x19 when using mirror
    // when module = 0x09: overworld
    //    sub_module = 0x00 normal gameplay in overworld
    //               = 0x0e
    //      sub_sub_module = 0x01 in item menu
    //                     = 0x02 in dialog with NPC
    //               = 0x23 transitioning from light world to dark world or vice-versa
    // when module = 0x12: Link is dying
    //    sub_module = 0x00
    //               = 0x02 bonk
    //               = 0x03 black oval closing in
    //               = 0x04 red screen and spinning animation
    //               = 0x05 red screen and Link face down
    //               = 0x06 fade to black
    //               = 0x07 game over animation
    //               = 0x08 game over screen done
    //               = 0x09 save and continue menu
    sub_module = bus::read_u8(0x7E0011);

    // sub-sub-module goes from 01 to 0f during special animations such as link walking up/down stairs and
    // falling from ceiling and used as a counter for orange/blue barrier blocks transition going up/down
    sub_sub_module = bus::read_u8(0x7E00B0);
  }

  void fetch() {
    // read frame counter (increments from 00 to FF and wraps around):
    frame = bus::read_u8(0x7E001A);

    // fetch various room indices and flags about where exactly Link currently is:
    in_dark_world = bus::read_u8(0x7E0FFF);
    in_dungeon = bus::read_u8(0x7E001B);
    overworld_room = bus::read_u16(0x7E008A);
    dungeon_room = bus::read_u16(0x7E00A0);

    dungeon = bus::read_u16(0x7E040C);
    dungeon_entrance = bus::read_u16(0x7E010E);

    // compute aggregated location for Link into a single 24-bit number:
    actual_location =
      uint32(in_dark_world & 1) << 17 |
      uint32(in_dungeon & 1) << 16 |
      uint32(in_dungeon != 0 ? dungeon_room : overworld_room);

    // last overworld x,y coords are cached in WRAM; only used for "simple" exits from caves:
    last_overworld_x = bus::read_u16(0x7EC14A);
    last_overworld_y = bus::read_u16(0x7EC148);

    if (is_it_a_bad_time()) {
      //if (!can_sample_location()) {
      //  x = 0xFFFF;
      //  y = 0xFFFF;
      //}
      return;
    }

    // $7E0410 = OW screen transitioning directional
    //ow_screen_transition = bus::read_u8(0x7E0410);

    // Don't update location until screen transition is complete:
    if (can_sample_location() && !is_in_screen_transition()) {
      last_location = location;
      location = actual_location;

      // clear out list of room changes if location changed:
      if (last_location != location) {
        //message("room from 0x" + fmtHex(last_location, 6) + " to 0x" + fmtHex(location, 6));

        // disown any of our torches:
        for (uint t = 0; t < 0x10; t++) {
          torchOwner[t] = -2;
        }
      }
    }

    x = bus::read_u16(0x7E0022);
    y = bus::read_u16(0x7E0020);

    // get screen x,y offset by reading BG2 scroll registers:
    xoffs = int16(bus::read_u16(0x7E00E2)) - int16(bus::read_u16(0x7E011A));
    yoffs = int16(bus::read_u16(0x7E00E8)) - int16(bus::read_u16(0x7E011C));

    fetch_sprites();

    fetch_sram();

    fetch_objects();

    fetch_ancillae();

    fetch_tilemap_changes();

    fetch_torches();
  }

  void fetch_sfx() {
    if (is_it_a_bad_time()) {
      sfx1 = 0;
      sfx2 = 0;
      return;
    }

    // NOTE: sfx are 6-bit values with top 2 MSBs indicating panning:
    //   00 = center, 01 = right, 10 = left, 11 = left

    uint8 lfx1 = bus::read_u8(0x7E012E);
    // filter out unwanted synced sounds:
    switch (lfx1) {
      case 0x2B: break; // low life warning beep
      default:
        sfx1 = lfx1;
    }

    uint8 lfx2 = bus::read_u8(0x7E012F);
    // filter out unwanted synced sounds:
    switch (lfx2) {
      case 0x0C: break; // text scrolling flute noise
      case 0x10: break; // switching to map sound effect
      case 0x11: break; // menu screen going down
      case 0x12: break; // menu screen going up
      case 0x20: break; // switch menu item
      case 0x24: break; // switching between different mode 7 map perspectives
      default:
        sfx2 = lfx2;
    }
  }

  bool is_frozen() {
    return bus::read_u8(0x7E02E4) != 0;
  }

  void fetch_sram() {
    // don't fetch latest SRAM when Link is frozen e.g. opening item chest for heart piece -> heart container:
    if (is_frozen()) return;

    bus::read_block_u8(0x7EF000, 0, 0x500, sram);
  }

  void fetch_objects() {
    if (!enableObjectSync) return;
    if (is_dead()) return;

    // $7E0D00 - $7E0FA0
    uint i = 0;

    bus::read_block_u8(0x7E0D00, 0, 0x2A0, objectsBlock);
    for (i = 0; i < 0x10; i++) {
      auto @en = @objects[i];
      if (@en is null) {
        @en = @objects[i] = GameSprite();
      }
      // copy in facts about each enemy from the large block of WRAM:
      objects[i].readFromBlock(objectsBlock, i);
    }
  }

  void fetch_sprites() {
    numsprites = 0;
    sprites.resize(0);
    if (is_it_a_bad_time()) {
      //message("clear sprites");
      return;
    }

    // read OAM offset where link's sprites start at:
    int link_oam_start = bus::read_u16(0x7E0352) >> 2;
    //message(fmtInt(link_oam_start));

    // read in relevant sprites from OAM:
    array<uint8> oam(0x220);
    ppu::oam.read_block_u8(0, 0, 0x220, oam);

    // extract OAM sprites to class instances:
    sprites.reserve(128);
    for (int i = 0x00; i <= 0x7f; i++) {
      //sprs[i].fetchOAM(i);
      sprs[i].decodeOAMArray(oam, i);
    }

    // start from reserved region for Link (either at 0x64 or ):
    for (int j = 0; j < 0x0C; j++) {
      auto i = (link_oam_start + j) & 0x7F;

      auto @spr = sprs[i];
      // skip OAM sprite if not enabled:
      if (!spr.is_enabled) continue;

      //message("[" + fmtInt(spr.index) + "] " + fmtInt(spr.x) + "," + fmtInt(spr.y) + "=" + fmtInt(spr.chr));

      // append the sprite to our array:
      sprites.resize(++numsprites);
      @sprites[numsprites-1] = spr;
    }

    // don't sync OAM beyond link's body during or after GAME OVER animation after death:
    if (is_dead()) return;

    // capture effects sprites:
    for (int i = 0x00; i <= 0x7f; i++) {
      // skip already synced Link sprites:
      if ((i >= link_oam_start) && (i < link_oam_start + 0x0C)) continue;

      auto @spr = sprs[i];
      // skip OAM sprite if not enabled:
      if (!spr.is_enabled) continue;

      auto chr = spr.chr;
      if (chr >= 0x100) continue;

      if (
        // sparkles around sword spin attack AND magic boomerang:
           chr == 0x80 || chr == 0x83 || chr == 0xb7
        // when boomerang hits solid tile:
        || chr == 0x81 || chr == 0x82
        // exclusively for spin attack:
        || chr == 0x8c || chr == 0x92 || chr == 0x93 || chr == 0xd6 || chr == 0xd7
        // bush leaves
        || chr == 0x59
        // cut grass
        || chr == 0xe2 || chr == 0xf2
        // pot shards or stone shards (large and small)
        || chr == 0x58 || chr == 0x48
        // boomerang
        || chr == 0x26
        // magic powder
        || chr == 0x09 || chr == 0x0a
        // magic cape
        || chr == 0x86 || chr == 0xa9 || chr == 0x9b
        // quake & ether:
        || chr == 0x40 || chr == 0x42 || chr == 0x44 || chr == 0x46 || chr == 0x48 || chr == 0x4a || chr == 0x4c || chr == 0x4e
        || chr == 0x60 || chr == 0x62 || chr == 0x63 || chr == 0x64 || chr == 0x66 || chr == 0x68 || chr == 0x6a
        // push block
        || chr == 0x0c
        // large stone
        || chr == 0x4a
        // holding pot / bush or small stone or sign
        || chr == 0x46 || chr == 0x44 || chr == 0x42
        // follower:
        || chr == 0x20 || chr == 0x22
      ) {
        // append the sprite to our array:
        sprites.resize(++numsprites);
        @sprites[numsprites-1] = spr;
        continue;
      }

      auto @sprp1 = spr;
      if (i > 0) {
        @sprp1 = sprs[i-1];
      }
      // shadow underneath pot / bush or small stone
      if (chr == 0x6c && (sprp1.chr == 0x46 || sprp1.chr == 0x44 || sprp1.chr == 0x42)) {
        // append the sprite to our array:
        sprites.resize(++numsprites);
        @sprites[numsprites-1] = spr;
        continue;
      }

      auto @sprn1 = spr;
      if (i <= 0x7E) {
        @sprn1 = sprs[i+1];
      }
      if (
        // water under follower:
           (chr == 0xd8 && (sprn1.chr == 0xd8 || sprn1.chr == 0x22 || sprn1.chr == 0x20))
        || (chr == 0xd9 && (sprn1.chr == 0xd9 || sprn1.chr == 0x22 || sprn1.chr == 0x20))
        || (chr == 0xda && (sprn1.chr == 0xda || sprn1.chr == 0x22 || sprn1.chr == 0x20))
        // grass under follower:
        || (chr == 0xc8 && (sprn1.chr == 0xc8 || sprn1.chr == 0x22 || sprn1.chr == 0x20))
        || (chr == 0xc9 && (sprn1.chr == 0xc9 || sprn1.chr == 0x22 || sprn1.chr == 0x20))
        || (chr == 0xca && (sprn1.chr == 0xca || sprn1.chr == 0x22 || sprn1.chr == 0x20))
      ) {
        // append the sprite to our array:
        sprites.resize(++numsprites);
        @sprites[numsprites-1] = spr;
        continue;
      }
    }
  }

  void capture_sprites_vram() {
    for (int i = 0; i < numsprites; i++) {
      auto @spr = @sprites[i];
      capture_sprite(spr);
    }
  }

  void capture_sprite(Sprite &sprite) {
    //message("capture_sprite " + fmtInt(sprite.index));
    // load character(s) from VRAM:
    if (sprite.size == 0) {
      // 8x8 sprite:
      //message("capture  x8 CHR=" + fmtHex(sprite.chr, 3));
      if (chrs[sprite.chr].length() == 0) {
        chrs[sprite.chr].resize(16);
        ppu::vram.read_block(ppu::vram.chr_address(sprite.chr), 0, 16, chrs[sprite.chr]);
      }
    } else {
      // 16x16 sprite:
      //message("capture x16 CHR=" + fmtHex(sprite.chr, 3));
      if (chrs[sprite.chr + 0x00].length() == 0) {
        chrs[sprite.chr + 0x00].resize(16);
        ppu::vram.read_block(ppu::vram.chr_address(sprite.chr + 0x00), 0, 16, chrs[sprite.chr + 0x00]);
      }
      if (chrs[sprite.chr + 0x01].length() == 0) {
        chrs[sprite.chr + 0x01].resize(16);
        ppu::vram.read_block(ppu::vram.chr_address(sprite.chr + 0x01), 0, 16, chrs[sprite.chr + 0x01]);
      }
      if (chrs[sprite.chr + 0x10].length() == 0) {
        chrs[sprite.chr + 0x10].resize(16);
        ppu::vram.read_block(ppu::vram.chr_address(sprite.chr + 0x10), 0, 16, chrs[sprite.chr + 0x10]);
      }
      if (chrs[sprite.chr + 0x11].length() == 0) {
        chrs[sprite.chr + 0x11].resize(16);
        ppu::vram.read_block(ppu::vram.chr_address(sprite.chr + 0x11), 0, 16, chrs[sprite.chr + 0x11]);
      }
    }
  }

  void fetch_tilemap_changes() {
    if (is_dead()) return;

    bool clear = false;
    /*
    if (module == 0x09 && sub_module == 0x05) {
      // scrolling overworld areas:
      clear = true;
    } else
    */
    if (actual_location != last_location) {
      // generic location changed event:
      clear = true;
    }

    if (!clear) return;

    // clear tilemap to -1 when changing rooms:
    tilemap.reset(area_size);

    if (actual_location != last_location) {
      //tilemap_testcase();
    }
  }

  // intercept 8-bit writes to a 16-bit array in WRAM at $7e2000:
  void tilemap_written(uint32 addr, uint8 value) {
    if (is_it_a_bad_time()) {
      return;
    }

    // overworld only for the moment:
    if (module != 0x09) {
      return;
    }

    // don't fetch tilemap during lost woods transition:
    if (sub_module >= 0x0d && sub_module < 0x16) return;
    // don't fetch tilemap during screen transition:
    if (sub_module >= 0x01 && sub_module < 0x07) return;
    // or during LW/DW transition:
    if (sub_module >= 0x23) return;

    // figure out offset from $7e2000:
    addr -= 0x7e2000;

    // mask off low bit of offset and divide by 2 for 16-bit index:
    uint i = (addr & 0x1ffe) >> 1;

    // apply the write to either side of the uint16 (upcast to int32):
    if ((addr & 1) == 1) {
      // high byte:
      tilemap[i] = int32( (uint16(tilemap[i]) & 0x00ff) | (int32(value) << 8) );
      //message("tilemap[0x" + fmtHex(i, 4) + "]=0x" + fmtHex(tilemap[i], 4));
    } else {
      // low byte:
      tilemap[i] = int32( (uint16(tilemap[i]) & 0xff00) | (int32(value)) );
    }
  }

  void fetch_ancillae() {
    if (is_dead()) return;

    // update ancillae array from WRAM:
    array<uint8> u280(0x32);
    array<uint8> u380(0x4F);
    array<uint8> uBF0(0xAA);
    bus::read_block_u8(0x7E0280, 0, 0x32, u280);
    bus::read_block_u8(0x7E0380, 0, 0x4F, u380);
    bus::read_block_u8(0x7E0BF0, 0, 0xAA, uBF0);
    for (uint i = 0; i < 0x0A; i++) {
      auto @anc = ancillae[i];
      anc.readRAM(i, u280, u380, uBF0);

      // Update ownership:
      if (ancillaeOwner[i] == index) {
        anc.requestOwnership = false;
        if (anc.type == 0) {
          ancillaeOwner[i] = -2;
        }
      } else if (ancillaeOwner[i] == -1) {
        if (anc.type != 0) {
          ancillaeOwner[i] = index;
          anc.requestOwnership = false;
        }
      } else if (ancillaeOwner[i] == -2) {
        ancillaeOwner[i] = -1;
        anc.requestOwnership = false;
      }
    }
  }

  void fetch_torches() {
    if (!is_in_dungeon()) return;
    if (is_dead()) return;

    torchTimers.resize(0x10);
    bus::read_block_u8(0x7E04F0, 0, 0x10, torchTimers);
  }

  bool is_torch_lit(uint8 t) {
    if (!is_in_dungeon()) return false;
    if (t >= 0x10) return false;

    auto idx = (t << 1) + bus::read_u16(0x7E0478);
    auto tm = bus::read_u16(0x7E0540 + idx);
    return (tm & 0x8000) == 0x8000;
  }

  void serialize_location(array<uint8> &r) {
    r.write_u8(uint8(0x01));

    r.write_u8(module);
    r.write_u8(sub_module);
    r.write_u8(sub_sub_module);

    r.write_u32(location);

    r.write_u16(x);
    r.write_u16(y);

    r.write_u16(dungeon);
    r.write_u16(dungeon_entrance);

    r.write_u16(last_overworld_x);
    r.write_u16(last_overworld_y);

    r.write_u16(xoffs);
    r.write_u16(yoffs);

    r.write_u16(player_color);
  }

  void serialize_sfx(array<uint8> &r) {
    r.write_u8(uint8(0x02));

    r.write_u8(sfx1);
    r.write_u8(sfx2);
  }

  void serialize_sram(array<uint8> &r, uint16 start, uint16 endExclusive) {
    r.write_u8(uint8(0x06));

    r.write_u16(start);
    uint16 count = uint16(endExclusive - start);
    r.write_u16(count);
    for (uint i = 0; i < count; i++) {
      r.write_u8(sram[start + i]);
    }
  }

  void serialize_tilemaps(array<uint8> &r) {
    r.write_u8(uint8(0x07));

    tilemap.serialize(r);
  }

  void serialize_objects(array<uint8> &r) {
    if (!enableObjectSync) return;

    r.write_u8(uint8(0x08));

    // 0x2A0 bytes
    r.write_arr(objectsBlock);
  }

  void serialize_ancillae(array<uint8> &r) {
    if (ancillaeOwner.length() == 0) return;
    if (ancillae.length() == 0) return;

    r.write_u8(uint8(0x09));

    uint8 count = 0;
    for (uint i = 0; i < 0x0A; i++) {
      if (!ancillae[i].requestOwnership) {
        if (ancillaeOwner[i] != index && ancillaeOwner[i] != -1) continue;
      }
      if (!ancillae[i].is_syncable()) continue;

      count++;
    }

    // count of active+owned ancillae:
    r.write_u8(count);
    for (uint i = 0; i < 0x0A; i++) {
      if (!ancillae[i].requestOwnership) {
        if (ancillaeOwner[i] != index && ancillaeOwner[i] != -1) continue;
      }
      if (!ancillae[i].is_syncable()) continue;

      ancillae[i].serialize(r);
    }
  }

  void serialize_torches(array<uint8> &r) {
    // dungeon torches:
    r.write_u8(uint8(0x0A));

    uint8 count = 0;
    for (uint8 t = 0; t < 0x10; t++) {
      if (torchOwner[t] != index) continue;
      count++;
    }

    //message("torches="+fmtInt(count));
    r.write_u8(count);
    for (uint8 t = 0; t < 0x10; t++) {
      if (torchOwner[t] != index) continue;
      r.write_u8(t);
      r.write_u8(torchTimers[t]);
    }
  }

  void serialize_name(array<uint8> &r) {
    r.write_u8(uint8(0x0C));

    r.write_str(namePadded);
  }

  uint send_sprites(uint p) {
    uint len = sprites.length();

    uint start = 0;
    uint end = len;

    // never send the shadow sprite or bomb sprite data (or anything for chr >= 0x80):
    array<bool> paletteSent(8);
    array<bool> chrSent(0x80);
    chrSent[0x6c] = true;
    chrSent[0x6d] = true;
    chrSent[0x6e] = true;
    chrSent[0x6f] = true;
    chrSent[0x7c] = true;
    chrSent[0x7d] = true;
    chrSent[0x7e] = true;
    chrSent[0x7f] = true;

    // send out possibly multiple packets to cover all sprites:
    while (start < end) {
      array<uint8> r = create_envelope();

      // serialize_sprites:
      if (start == 0) {
        // start of sprites:
        r.write_u8(uint8(0x03));
      } else {
        // continuation of sprites:
        r.write_u8(uint8(0x04));
        r.write_u8(uint8(start));
      }

      uint markLen = r.length();
      r.write_u8(uint8(end - start));

      uint mark = r.length();

      uint i;
      //message("build start=" + fmtInt(start));
      for (i = start; i < end; i++) {
        auto @spr = sprites[i];
        auto chr = spr.chr;
        auto index = spr.index;
        uint pal = spr.palette;
        auto b4 = spr.b4;

        // do we need to send the VRAM data?
        if ((chr < 0x80) && !chrSent[chr]) {
          index |= 0x80;
        }
        // do we need to send the palette data?
        if (!paletteSent[pal]) {
          b4 |= 0x80;
        }

        mark = r.length();
        //message("  mark=" + fmtInt(mark));

        // emit the OAM data:
        r.write_u8(index);
        r.write_u8(spr.b0);
        r.write_u8(spr.b1);
        r.write_u8(spr.b2);
        r.write_u8(spr.b3);
        r.write_u8(b4);

        // send VRAM data along:
        if ((index & 0x80) != 0) {
          r.write_arr(chrs[chr+0x00]);
          if (spr.size != 0) {
            r.write_arr(chrs[chr+0x01]);
            r.write_arr(chrs[chr+0x10]);
            r.write_arr(chrs[chr+0x11]);
          }
        }

        // include the palette for this sprite:
        if ((b4 & 0x80) != 0) {
          // sample the palette:
          uint cgaddr = (pal + 8) << 4;
          for (uint k = cgaddr; k < cgaddr + 16; k++) {
            r.write_u16(ppu::cgram[k]);
          }
        }

        // check length of packet:
        if (r.length() <= MaxPacketSize) {
          // mark data as sent:
          if ((index & 0x80) != 0) {
            chrSent[chr+0x00] = true;
            chrs[chr+0x00].resize(0);
            if (spr.size != 0) {
              chrSent[chr+0x01] = true;
              chrSent[chr+0x10] = true;
              chrSent[chr+0x11] = true;
              chrs[chr+0x01].resize(0);
              chrs[chr+0x10].resize(0);
              chrs[chr+0x11].resize(0);
            }
          }
          if ((b4 & 0x80) != 0) {
            paletteSent[pal] = true;
          }
        } else {
          // back out the last sprite:
          r.removeRange(mark, r.length() - mark);

          // continue at the last sprite in the next packet:
          //message("  scratch last mark");
          break;
        }
      }

      r[markLen] = uint8(i - start);
      start = i;

      // send this packet:
      p = send_packet(r, p);
    }

    return p;
  }

  array<uint8> @create_envelope(uint8 kind = 0x01) {
    array<uint8> @envelope = {};
    envelope.reserve(MaxPacketSize);

    // server envelope:
    {
      // header:
      envelope.write_u16(uint16(25887));
      // server protocol 2:
      envelope.write_u8(uint8(0x02));
      // group name: (20 bytes exactly)
      envelope.write_str(settings.GroupPadded);
      // message kind:
      envelope.write_u8(kind);
      // what we think our index is:
      envelope.write_u16(uint16(index));
    }

    // script protocol:
    envelope.write_u8(uint8(script_protocol));

    // protocol starts with frame number to correlate them together:
    envelope.write_u8(frame);

    return envelope;
  }

  array<uint16> maxSize(5);

  uint send_packet(array<uint8> &in envelope, uint p) {
    uint len = envelope.length();
    if (len > MaxPacketSize) {
      message("packet[" + fmtInt(p) + "] too big to send! " + fmtInt(len) + " > " + fmtInt(MaxPacketSize));
      return p;
    }

    // send packet to server:
    //message("sent " + fmtInt(envelope.length()) + " bytes");
    sock.send(0, len, envelope);

    // stats on max packet size per 128 frames:
    if (debugNet) {
      if (len > maxSize[p]) {
        maxSize[p] = len;
      }
      if ((frame & 0x7F) == 0) {
        message("["+fmtInt(p)+"] = " + fmtInt(maxSize[p]));
        maxSize[p] = 0;
      }
    }
    p++;

    return p;
  }

  void send() {
    uint p = 0;

    // check if we need to detect our local index:
    if (index == -1) {
      // request our index; receive() will take care of the response:
      array<uint8> request = create_envelope(0x00);
      p = send_packet(request, p);
    }

    // send main packet:
    {
      array<uint8> envelope = create_envelope();

      serialize_location(envelope);
      serialize_name(envelope);
      serialize_sfx(envelope);

      if (!settings.RaceMode) {
        serialize_ancillae(envelope);
        serialize_objects(envelope);
      }

      p = send_packet(envelope, p);
    }

    // send another packet:
    p = send_sprites(p);

    if (!settings.RaceMode) {
      // send packet every other frame:
      if ((frame & 1) == 0) {
        array<uint8> envelope = create_envelope();

        serialize_torches(envelope);
        serialize_tilemaps(envelope);

        p = send_packet(envelope, p);
      }

      // send SRAM updates once every 16 frames:
      if ((frame & 15) == 0) {
        array<uint8> envelope = create_envelope();
        rom.serialize_sram_ranges(envelope, serializeSramDelegate);
        p = send_packet(envelope, p);
      }

      // send dungeon and overworld SRAM alternating every 16 frames:
      if ((frame & 31) == 0) {
        array<uint8> envelope = create_envelope();
        serialize_sram(envelope,   0x0, 0x250); // dungeon rooms
        p = send_packet(envelope, p);
      }
      if ((frame & 31) == 16) {
        array<uint8> envelope = create_envelope();
        serialize_sram(envelope, 0x280, 0x340); // overworld events; heart containers, overlays
        p = send_packet(envelope, p);
      }
    }
  }

  array<string> received_items(0);
  array<string> received_quests(0);
  void collectNotifications(const string &in name) {
    if (name.length() == 0) return;

    if (name.length() >= 2 && name.slice(0, 2) == "Q#") {
      received_quests.insertLast(name.slice(2));
      return;
    }
    received_items.insertLast(name);
  }

  void update_items() {
    if (is_it_a_bad_time()) return;
    // don't fetch latest SRAM when Link is frozen e.g. opening item chest for heart piece -> heart container:
    if (is_frozen()) return;

    auto @syncables = rom.syncables;

    // track names of items received:
    received_items.reserve(syncables.length());
    received_items.resize(0);
    received_quests.reserve(16);
    received_quests.resize(0);

    uint len = players.length();
    uint slen = syncables.length();
    for (uint k = 0; k < slen; k++) {
      auto @syncable = syncables[k];
      // TODO: for some reason syncables.length() is one higher than it should be.
      if (syncable is null) continue;

      // start the sync process for each syncable item in SRAM:
      syncable.start(sram);

      // apply remote values from all other active players:
      for (uint i = 0; i < len; i++) {
        auto @remote = players[i];
        if (remote is null) continue;
        if (remote is this) continue;
        if (remote.ttl <= 0) continue;

        // apply the remote values:
        syncable.apply(remote);
      }

      // write back any new updates:
      syncable.finish(itemReceivedDelegate);
    }

    // Generate notification messages:
    if (received_items.length() > 0) {
      for (uint i = 0; i < received_items.length(); i++) {
        notify("Got " + received_items[i]);
      }
    }
    if (received_quests.length() > 0) {
      for (uint i = 0; i < received_quests.length(); i++) {
        notify("Quest " + received_quests[i]);
      }
    }
  }

  void update_overworld() {
    if (is_it_a_bad_time()) return;

    uint len = players.length();

    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote is this) continue;
      if (remote.ttl <= 0) continue;

      // read current state from SRAM:
      for (uint a = 0; a < 0x80; a++) {
        areas[a].start(sram);
      }
    }

    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote is this) continue;
      if (remote.ttl <= 0) continue;

      for (uint a = 0; a < 0x80; a++) {
        areas[a].apply(remote);
      }
    }

    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote is this) continue;
      if (remote.ttl <= 0) continue;

      for (uint a = 0; a < 0x80; a++) {
        // write new state to SRAM:
        areas[a].finish();
      }
    }
  }

  void update_rooms() {
    uint len = players.length();

    // $000 - $24F : Data for Rooms (two bytes per room)
    //
    // High Byte               Low Byte
    // d d d d b k ck cr       c c c c q q q q
    //
    // c - chest, big key chest, or big key lock. Any combination of them totalling to 6 is valid.
    // q - quadrants visited:
    // k - key or item (such as a 300 rupee gift)
    // d - door opened (either unlocked, bombed or other means)
    // r - special rupee tiles, whether they've been obtained or not.
    // b - boss battle won
    //
    // qqqq corresponds to 4321, so if quadrants 4 and 1 have been "seen" by Link, then qqqq will look like 1001. The quadrants are laid out like so in each room:

    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote is this) continue;
      if (remote.ttl <= 0) continue;

      // read current state from SRAM:
      for (uint a = 0; a < 0x128; a++) {
        rooms[a].start(sram);
      }
    }

    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote is this) continue;
      if (remote.ttl <= 0) continue;

      for (uint a = 0; a < 0x128; a++) {
        rooms[a].apply(remote);
      }
    }

    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote is this) continue;
      if (remote.ttl <= 0) continue;

      // write new state to SRAM:
      for (uint a = 0; a < 0x128; a++) {
        rooms[a].finish();
      }
    }
  }

  void tilemap_testcase() {
    if (actual_location == 0x02005b) {
      message("testcase!");
      tilemap[0x0aae]=0x0dc5;
      tilemap[0x0aad]=0x0dc5;
      tilemap[0x0aac]=0x0dc5;
      tilemap[0x0aab]=0x0dc5;
      tilemap[0x0a6f]=0x0dc5;
      tilemap[0x0a6e]=0x0dc5;
      tilemap[0x0a6d]=0x0dc5;
      tilemap[0x0a6c]=0x0dc5;
      tilemap[0x0a6b]=0x0dc5;
      tilemap[0x0a6a]=0x0dc5;
      tilemap[0x0a30]=0x0dc5;
      tilemap[0x0a2f]=0x0dc5;
      tilemap[0x0a2e]=0x0dc5;
      tilemap[0x0a2d]=0x0dc5;
      tilemap[0x0a2c]=0x0dc5;
      tilemap[0x0a2b]=0x0dc5;
      tilemap[0x0a2a]=0x0dc5;
      tilemap[0x0aed]=0x0dc5;
      tilemap[0x0aec]=0x0dc5;
      tilemap[0x0b31]=0x0dcd;
      tilemap[0x0b32]=0x0dce;
      tilemap[0x0b71]=0x0dcf;
      tilemap[0x0b72]=0x0dd0;
      tilemap[0x09f3]=0x0dc5;
      tilemap[0x09f2]=0x0dc5;
      tilemap[0x09f1]=0x0dc5;
      tilemap[0x09f0]=0x0dc5;
      tilemap[0x09ef]=0x0dc5;
      tilemap[0x09ee]=0x0dc5;
      tilemap[0x09ed]=0x0dc5;
      tilemap[0x09ec]=0x0dc5;
      tilemap[0x09eb]=0x0dc5;
    } else if (actual_location == 0x020065) {
      message("testcase!");
      tilemap[0x0242]=0x0dc6;
      tilemap[0x03c4]=0x0dc7;
      tilemap[0x0444]=0x0dc7;
      tilemap[0x0484]=0x0dc7;
      tilemap[0x04c4]=0x0dc7;
      tilemap[0x0745]=0x0dc7;
    } else if (actual_location == 0x02005d) {
      message("testcase!");
      tilemap[0x0217]=0x0dc7;
      tilemap[0x0198]=0x0dcd;
      tilemap[0x0199]=0x0dce;
      tilemap[0x01d8]=0x0dcf;
      tilemap[0x01d9]=0x0dd0;
      tilemap[0x0197]=0x0dcb;
    } else if (actual_location == 0x000013) {
      message("testcase!");
      tilemap[0x030e]=0x0dc7;
      tilemap[0x024e]=0x0dcd;
      tilemap[0x024f]=0x0dce;
      tilemap[0x028e]=0x0dcf;
      tilemap[0x028f]=0x0dd0;
      tilemap[0x03d4]=0x0dc7;
      tilemap[0x03d3]=0x0dc7;
      tilemap[0x03d1]=0x0dc7;
      tilemap[0x03d0]=0x0dc7;
      tilemap[0x03d7]=0x0dc7;
      tilemap[0x03d8]=0x0dc7;
      tilemap[0x03da]=0x0dc7;
      tilemap[0x03db]=0x0dc7;
      tilemap[0x0417]=0x0dc7;
      tilemap[0x0418]=0x0dc7;
      tilemap[0x041a]=0x0dc7;
      tilemap[0x041b]=0x0dc7;
      tilemap[0x0414]=0x0dc7;
      tilemap[0x0413]=0x0dc7;
      tilemap[0x0411]=0x0dc7;
      tilemap[0x0410]=0x0dc7;
      tilemap[0x03dd]=0x0dc5;
    } else {
      message("no testcase");
    }
  }

  void update_tilemap() {
    // TODO: sync dungeon tilemap changes
    if (module != 0x09) return;

    // don't update tilemap during LW/DW transition:
    if (sub_module >= 0x23) return;

    // don't write to VRAM during area transition:
    bool write_to_vram = true;
    if (sub_module > 0x00 && sub_module < 0x07) write_to_vram = false;

    // read WRAM values to determine VRAM write bounds:
    tilemap.determine_vram_bounds();

    uint len = players.length();

    // integrate tilemap changes from other players:
    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote is this) continue;
      if (remote.ttl <= 0) continue;
      if (!is_really_in_same_location(remote.location)) continue;

      // TODO: may need to order updates by timestamp - e.g. sanctuary doors opening animation
      for (uint j = 0; j < remote.tilemapRuns.length(); j++) {
        auto @run = remote.tilemapRuns[j];
        // apply the run to the local tilemap state and update VRAM if applicable on screen:
        tilemap.apply(run, write_to_vram);
      }
    }
  }

  void update_ancillae() {
    if (is_dead()) return;

    uint len = players.length();

    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote.ttl <= 0) continue;
      if (!is_really_in_same_location(remote.location)) continue;

      //message("[" + fmtInt(i) + "].ancillae.len = " + fmtInt(remote.ancillae.length()));
      if (remote is this) {
        continue;
      }

      uint alen = remote.ancillae.length();
      if (alen > 0) {
        for (uint j = 0; j < alen; j++) {
          auto @an = remote.ancillae[j];
          auto k = an.index;

          if (k < 0x05) {
            // Doesn't work; needs more debugging.
            if (false) {
              // if local player picks up remotely owned ancillae:
              if (ancillae[k].held == 3 && an.held != 3) {
                an.requestOwnership = false;
                ancillae[k].requestOwnership = true;
                ancillaeOwner[k] = index;
              }
            }
          }

          // ownership transfer:
          if (an.requestOwnership) {
            ancillae[k].requestOwnership = false;
            ancillaeOwner[k] = remote.index;
          }

          if (ancillaeOwner[k] == remote.index) {
            an.writeRAM();
            if (an.type == 0) {
              // clear owner if type went to 0:
              ancillaeOwner[k] = -1;
              ancillae[k].requestOwnership = false;
            }
          } else if (ancillaeOwner[k] == -1 && an.type != 0) {
            an.writeRAM();
            ancillaeOwner[k] = remote.index;
            ancillae[k].requestOwnership = false;
          }
        }
      }

      continue;
    }
  }

  // local player owns whatever it spawns:
  void on_object_init(uint32 pc) {
    auto j = cpu::r.x;
    objectOwner[j] = index;
    message("owner["+fmtHex(j,1)+"]="+fmtInt(objectOwner[j]));
  }

  array<int> objectOwner(0x10);
  array<int> objectHeat(0x10);
  void update_objects() {
    // clear ownership of local dead objects:
    for (uint j = 0; j < 0x10; j++) {
      GameSprite l;
      l.readRAM(j);

      if (!l.is_enabled) {
        if (objectHeat[j] > 0) {
          objectHeat[j]--;
          if (objectHeat[j] == 0) {
            objectOwner[j] = -2;
          }
        }

        if (objectOwner[j] == index) {
          objectOwner[j] = -2;
          objectHeat[j] = 32;
        } else if (objectOwner[j] >= 0) {
          // locally destroyed the object:
          objectOwner[j] = index;
          objectHeat[j] = 32;
        }
      }
    }

    // sync in remote objects:
    uint len = players.length();
    for (uint i = 0; i < len; i++) {
      auto @remote = players[i];
      if (remote is null) continue;
      if (remote is local) continue;
      if (remote.ttl <= 0) continue;
      if (!is_really_in_same_location(remote.location)) {
        // free ownership of any objects left behind:
        for (uint j = 0; j < 0x10; j++) {
          if (objectOwner[j] == remote.index) {
            objectOwner[j] = -2;
            objectHeat[j] = 32;
          }
        }
        continue;
      }

      for (uint j = 0; j < 0x10; j++) {
        GameSprite r;
        r.readFromBlock(remote.objectsBlock, j);

        if (!r.is_enabled) {
          // release ownership if owned:
          if (objectOwner[j] == remote.index) {
            if (objectHeat[j] == 0) {
              //objectOwner[j] = -2;
              objectHeat[j] = 32;
            }
            r.writeRAM();
          }
          continue;
        }

        // only copy in picked-up objects:
        if (r.type != 0xEC) continue;

        GameSprite l;
        l.readRAM(j);

        if (objectOwner[j] >= 0) {
          // not the owning player?
          if (objectOwner[j] != remote.index) {
            continue;
          }
        } else {
          // wait for the heat to die down:
          if (objectHeat[j] > 0) continue;

          // now this remote player owns it since no one has before:
          objectOwner[j] = remote.index;
          message("owner["+fmtHex(j,1)+"]="+fmtInt(objectOwner[j]));
        }

        // translate it from picked-up to a normal object, else local Link holds it above his head:
        if (r.state == 0x0A) r.state = 0x09;

        r.writeRAM();
      }
    }
  }

  // update's link's tunic colors in his palette:
  void update_palette() {
    // make sure we're in a game module where Link is shown:
    if (module <= 0x05) return;
    if (module >= 0x14 && module <= 0x18) return;
    if (module >= 0x1B) return;

    // read OAM offset where link's sprites start at:
    uint link_oam_start = bus::read_u16(0x7E0352) >> 2;

    uint8 palette = 8;
    for (uint j = link_oam_start; j < link_oam_start + 0xC; j++) {
      Sprite sprite;
      sprite.fetchOAM(j);

      // looking for Link body sprites only to grab the palette number:
      if (!sprite.is_enabled) continue;
      //message("chr: " + fmtHex(sprite.chr, 3));
      if ((sprite.chr & 0x0f) >= 0x04) continue;
      if ((sprite.chr & 0xf0) >= 0x20) continue;

      palette = sprite.palette;
      //message("chr="+fmtHex(sprite.chr,3) + " pal="+fmtHex(sprite.palette,1));

      // assign light/dark palette colors:
      auto light = player_color;
      auto dark  = player_color_dark_75;
      for (uint i = 0, m = 1; i < 16; i++, m <<= 1) {
        if ((settings.SyncTunicLightColors & m) == m) {
          auto c = (128 + (palette << 4)) + i;
          auto color = ppu::cgram[c];
          if (color != light) {
            ppu::cgram[c] = light;
          }
        } else if ((settings.SyncTunicDarkColors & m) == m) {
          auto c = (128 + (palette << 4)) + i;
          auto color = ppu::cgram[c];
          if (color != dark) {
            ppu::cgram[c] = dark;
          }
        }
      }
    }
  }

  // Notifications system:
  array<string> notifications(0);
  void notify(const string &in msg) {
    notifications.insertLast(msg);
    message(msg);
  }

  int notificationFrameTimer = 0;
  int renderNotifications(int ei) {
    if (notifications.length() == 0) return ei;

    // pop off the first notification if its timer is expired:
    if (notificationFrameTimer++ >= 120) {
      notifications.removeAt(0);
      notificationFrameTimer = 0;
    }
    if (notifications.length() == 0) return ei;

    // only render first two notification messages:
    int count = notifications.length();
    if (count > 2) count = 2;

    if (font_set) {
      @ppu::extra.font = ppu::fonts[0];
      font_set = false;
    }
    ppu::extra.color = ppu::rgb(26, 26, 26);
    ppu::extra.outline_color = ppu::rgb(0, 0, 0);
    auto height = ppu::extra.font.height + 1;

    for (int i = 0; i < count; i++) {
      auto msg = notifications[i];

      auto row = count - i;
      auto @label = ppu::extra[ei++];
      label.reset();
      label.index = 127;
      label.source = 5;
      label.priority = 3;
      label.x = 2;
      label.y = 222 - (height * row);
      auto width = ppu::extra.font.measureText(msg);
      label.width = width + 2;
      label.height = ppu::extra.font.height + 2;
      label.text(1, 1, msg);
    }

    return ei;
  }
};
