SettingsWindow @settings;

class SettingsWindow {
  private GUI::Window @window;
  private GUI::LineEdit @txtServerAddress;
  private GUI::LineEdit @txtGroup;
  private GUI::LineEdit @txtName;
  private GUI::LineEdit @txtColor;
  private GUI::CheckLabel @chkTunic;
  private GUI::HorizontalSlider @slRed;
  private GUI::HorizontalSlider @slGreen;
  private GUI::HorizontalSlider @slBlue;
  private GUI::SNESCanvas @colorCanvas;
  private GUI::CheckLabel @chkShowLabels;
  private GUI::CheckLabel @chkShowMyLabel;
  private GUI::CheckLabel @chkRaceMode;
  private GUI::CheckLabel @chkDiscordEnable;
  private GUI::CheckLabel @chkDiscordPrivate;
  private GUI::ComboButton @ddlFont;
  private GUI::Button @ok;

  bool started;

  private string serverAddress;
  string ServerAddress {
    get { return serverAddress; }
    set { serverAddress = value; }
  }

  private string groupPadded;
  string GroupPadded {
    get { return groupPadded; }
  }

  private string groupTrimmed;
  string GroupTrimmed {
    get { return groupTrimmed; }
    set {
      groupTrimmed = value;
      groupPadded = padTo(value, 20);
    }
  }

  private string name;
  string Name {
    get { return name; }
    set { name = value; }
  }

  uint16 player_color;
  uint16 PlayerColor {
    get { return player_color; }
    set { player_color = value; }
  }

  private bool syncTunic;
  bool SyncTunic { get { return syncTunic; } }

  private uint16 syncTunicLightColors;
  uint16 SyncTunicLightColors { get { return syncTunicLightColors; } }

  private uint16 syncTunicDarkColors;
  uint16 SyncTunicDarkColors { get { return syncTunicDarkColors; } }

  private bool showLabels;
  bool ShowLabels { get { return showLabels; } }

  private bool showMyLabel;
  bool ShowMyLabel { get { return showMyLabel; } }

  private ppu::Font@ font;
  ppu::Font@ Font {
    get { return font; }
  }
  private uint fontIndex;
  uint FontIndex {
    get { return fontIndex; }
    set {
      fontIndex = value;
      @font = ppu::fonts[value];
      font_set = false; // global
    }
  }

  private bool raceMode;
  bool RaceMode {
    get { return raceMode; }
  }

  private bool discordEnable;
  bool DiscordEnable {
    get { return discordEnable; }
  }

  private bool discordPrivate;
  bool DiscordPrivate {
    get { return discordPrivate; }
  }

  private void setColorSliders() {
    // set the color sliders:
    slRed.position   = ( player_color        & 31);
    slGreen.position = ((player_color >>  5) & 31);
    slBlue.position  = ((player_color >> 10) & 31);
  }

  private void setColorText() {
    // set the color text display:
    txtColor.text = fmtHex(player_color, 4);
  }

  private void setServerSettingsGUI() {
    txtServerAddress.text = serverAddress;
    txtGroup.text = groupTrimmed;
  }

  private void setPlayerSettingsGUI() {
    txtName.text = name;
    chkTunic.checked = syncTunic;
    setColorSliders();
    setColorText();
  }

  private void setFeaturesGUI() {
    chkShowLabels.checked = showLabels;
    chkShowMyLabel.checked = showMyLabel;
    chkRaceMode.checked = raceMode;
    chkDiscordEnable.checked = discordEnable;
    chkDiscordPrivate.checked = discordPrivate;

    // set selected font option:
    ddlFont[fontIndex].setSelected();
  }

  private uint16 parse_player_color(string &in text) {
    uint64 value = text.hex();

    if (value > 0x7fff) value = 0x7fff;
    return uint16(value);
  }

  void load() {
    // try to load previous settings from disk:
    auto @doc = UserSettings::load("alttpo.bml");
    auto version = doc["version"].naturalOr(0);
    serverAddress = doc["server/address"].textOr(ServerAddress);
    if (version == 0) {
      if (serverAddress == "bittwiddlers.org") serverAddress = "alttp.online";
    }
    groupTrimmed = doc["server/group"].textOr(GroupTrimmed);
    name = doc["player/name"].textOr(Name);
    player_color = parse_player_color(doc["player/color"].textOr("0x" + fmtHex(player_color, 4)));
    syncTunic = doc["player/syncTunic"].booleanOr(true);
    syncTunicLightColors = doc["player/syncTunic/lightColors"].naturalOr(0x1400);
    syncTunicDarkColors = doc["player/syncTunic/darkColors"].naturalOr(0x0A00);
    if (version == 0) {
      if (syncTunicLightColors == 0x400) syncTunicLightColors = 0x1400;
      if (syncTunicLightColors == 0x200) syncTunicLightColors = 0x0A00;
    }

    showLabels = doc["feature/showLabels"].booleanOr(true);
    showMyLabel = doc["feature/showMyLabel"].booleanOr(false);
    FontIndex = doc["feature/fontIndex"].naturalOr(0);
    raceMode = doc["feature/raceMode"].booleanOr(false);
    discordEnable = doc["feature/discordEnable"].booleanOr(false);
    discordPrivate = doc["feature/discordPrivate"].booleanOr(false);

    // set GUI controls from values:
    setServerSettingsGUI();
    setPlayerSettingsGUI();
    setFeaturesGUI();

    // apply player name change:
    nameWasChanged(false);

    // apply color changes without persisting back to disk:
    colorWasChanged(false);
  }

  void save() {
    // grab latest values from GUI:
    ServerAddress = txtServerAddress.text;
    GroupTrimmed = txtGroup.text;
    Name = txtName.text;
    PlayerColor = parse_player_color(txtColor.text);

    syncTunic = chkTunic.checked;
    showLabels = chkShowLabels.checked;
    showMyLabel = chkShowMyLabel.checked;
    raceMode = chkRaceMode.checked;

    auto @doc = BML::Node();
    doc.create("version").value = "1";
    doc.create("server/address").value = ServerAddress;
    doc.create("server/group").value = GroupTrimmed;
    doc.create("player/name").value = Name;
    doc.create("player/color").value = "0x" + fmtHex(player_color, 4);
    doc.create("player/syncTunic").value = fmtBool(syncTunic);
    doc.create("player/syncTunic/lightColors").value = "0b" + fmtBinary(syncTunicLightColors, 16);
    doc.create("player/syncTunic/darkColors").value = "0b" + fmtBinary(syncTunicDarkColors, 16);
    doc.create("feature/showLabels").value = fmtBool(showLabels);
    doc.create("feature/showMyLabel").value = fmtBool(showMyLabel);
    doc.create("feature/fontIndex").value = fmtInt(fontIndex);
    doc.create("feature/raceMode").value = fmtBool(raceMode);
    doc.create("feature/discordEnable").value = fmtBool(discordEnable);
    doc.create("feature/discordPrivate").value = fmtBool(discordPrivate);
    UserSettings::save("alttpo.bml", doc);
  }

  SettingsWindow() {
    @window = GUI::Window(120, 32, true);
    window.title = "Join a Game";
    window.size = GUI::Size(280, 15*25);
    window.dismissable = false;

    auto vl = GUI::VerticalLayout();
    vl.setSpacing();
    vl.setPadding(5, 5);
    window.append(vl);
    {
      {
        auto @hz = GUI::HorizontalLayout();
        vl.append(hz, GUI::Size(-1, 0));

        auto @lbl = GUI::Label();
        lbl.text = "Address:";
        hz.append(lbl, GUI::Size(100, 0));

        @txtServerAddress = GUI::LineEdit();
        txtServerAddress.onChange(@GUI::Callback(save));
        hz.append(txtServerAddress, GUI::Size(-1, 20));
      }

      {
        auto @hz = GUI::HorizontalLayout();
        vl.append(hz, GUI::Size(-1, 0));

        auto @lbl = GUI::Label();
        lbl.text = "Group:";
        hz.append(lbl, GUI::Size(100, 0));

        @txtGroup = GUI::LineEdit();
        txtGroup.onChange(@GUI::Callback(save));
        hz.append(txtGroup, GUI::Size(-1, 20));
      }

      {
        auto @hz = GUI::HorizontalLayout();
        vl.append(hz, GUI::Size(-1, 0));

        auto @lbl = GUI::Label();
        lbl.text = "Player Name:";
        hz.append(lbl, GUI::Size(100, 0));

        @txtName = GUI::LineEdit();
        txtName.onChange(@GUI::Callback(txtNameChanged));
        hz.append(txtName, GUI::Size(-1, 20));
      }

      // player color:
      {
        {
          auto @hz = GUI::HorizontalLayout();
          vl.append(hz, GUI::Size(-1, 0));

          auto @lbl = GUI::Label();
          lbl.text = "Player Color:";
          hz.append(lbl, GUI::Size(100, 20));

          @txtColor = GUI::LineEdit();
          txtColor.text = "7fff";
          txtColor.onChange(@GUI::Callback(colorTextChanged));
          hz.append(txtColor, GUI::Size(-1, 20));
        }

        @chkTunic = GUI::CheckLabel();
        chkTunic.text = "Sync player color to Link's tunic";
        chkTunic.checked = true;
        chkTunic.onToggle(@GUI::Callback(chkTunicChanged));
        vl.append(chkTunic, GUI::Size(-1, 0));

        auto @chl = GUI::HorizontalLayout();
        vl.append(chl, GUI::Size(-1, 0));

        auto @cvl = GUI::VerticalLayout();
        chl.append(cvl, GUI::Size(-1, -1));
        {
          auto @hz = GUI::HorizontalLayout();
          cvl.append(hz, GUI::Size(-1, 0));

          auto @lbl = GUI::Label();
          lbl.text = "R";
          hz.append(lbl, GUI::Size(20, 20));

          @slRed = GUI::HorizontalSlider();
          hz.append(slRed, GUI::Size(-1, 0));
          slRed.length = 31;
          slRed.position = 31;
          slRed.onChange(@GUI::Callback(colorSliderChanged));
        }
        {
          auto @hz = GUI::HorizontalLayout();
          cvl.append(hz, GUI::Size(-1, 0));

          auto @lbl = GUI::Label();
          lbl.text = "G";
          hz.append(lbl, GUI::Size(20, 20));

          @slGreen = GUI::HorizontalSlider();
          hz.append(slGreen, GUI::Size(-1, 0));
          slGreen.length = 31;
          slGreen.position = 31;
          slGreen.onChange(@GUI::Callback(colorSliderChanged));
        }
        {
          auto @hz = GUI::HorizontalLayout();
          cvl.append(hz, GUI::Size(-1, 0));

          auto @lbl = GUI::Label();
          lbl.text = "B";
          hz.append(lbl, GUI::Size(20, 20));

          @slBlue = GUI::HorizontalSlider();
          hz.append(slBlue, GUI::Size(-1, 0));
          slBlue.length = 31;
          slBlue.position = 31;
          slBlue.onChange(@GUI::Callback(colorSliderChanged));
        }

        @colorCanvas = GUI::SNESCanvas();
        colorCanvas.size = GUI::Size(64, 64);
        colorCanvas.setAlignment(0.5, 0.5);
        colorCanvas.fill(0x7FFF | 0x8000);
        colorCanvas.update();
        chl.append(colorCanvas, GUI::Size(64, 64));
      }

      {
        auto @hz = GUI::HorizontalLayout();
        vl.append(hz, GUI::Size(-1, 0));

        @chkShowLabels = GUI::CheckLabel();
        chkShowLabels.text = "Show player labels";
        chkShowLabels.checked = true;
        chkShowLabels.onToggle(@GUI::Callback(chkShowLabelsChanged));
        hz.append(chkShowLabels, GUI::Size(-1, 0));

        @chkShowMyLabel = GUI::CheckLabel();
        chkShowMyLabel.text = "Show my label";
        chkShowMyLabel.checked = true;
        chkShowMyLabel.onToggle(@GUI::Callback(chkShowMyLabelChanged));
        hz.append(chkShowMyLabel, GUI::Size(-1, 0));
      }

      {
        auto @hz = GUI::HorizontalLayout();
        vl.append(hz, GUI::Size(-1, 0));

        auto @lbl = GUI::Label();
        lbl.text = "Label Font:";
        hz.append(lbl, GUI::Size(100, 0));

        @ddlFont = GUI::ComboButton();
        hz.append(ddlFont, GUI::Size(0, 0));

        uint len = ppu::fonts_count;
        for (uint i = 0; i < len; i++) {
          auto @di = GUI::ComboButtonItem();
          auto @f = ppu::fonts[i];
          di.text = f.displayName;
          ddlFont.append(di);
        }
        ddlFont[0].setSelected();

        ddlFont.onChange(@GUI::Callback(ddlFontChanged));
        ddlFont.enabled = true;
      }

      {
        auto @hz = GUI::HorizontalLayout();
        vl.append(hz, GUI::Size(-1, 0));

        @chkRaceMode = GUI::CheckLabel();
        chkRaceMode.text = "Race Mode";
        chkRaceMode.checked = false;
        chkRaceMode.onToggle(@GUI::Callback(chkRaceModeChanged));
        hz.append(chkRaceMode, GUI::Size(-1, 0));
      }

      {
        auto @hz = GUI::HorizontalLayout();
        vl.append(hz, GUI::Size(-1, 0));

        @chkDiscordEnable = GUI::CheckLabel();
        chkDiscordEnable.text = "Discord Integration";
        chkDiscordEnable.checked = false;
        chkDiscordEnable.onToggle(@GUI::Callback(chkDiscordEnableChanged));
        hz.append(chkDiscordEnable, GUI::Size(-1, 0));

        @chkDiscordPrivate = GUI::CheckLabel();
        chkDiscordPrivate.text = "Hide Group Name";
        chkDiscordPrivate.checked = false;
        chkDiscordPrivate.onToggle(@GUI::Callback(chkDiscordPrivateChanged));
        hz.append(chkDiscordPrivate, GUI::Size(-1, 0));
      }

      {
        auto @hz = GUI::HorizontalLayout();
        vl.append(hz, GUI::Size(-1, -1));

        @ok = GUI::Button();
        ok.text = "Connect";
        ok.onActivate(@GUI::Callback(startClicked));
        hz.append(ok, GUI::Size(-1, -1));
      }
    }

    vl.resize();
    window.visible = true;
    window.setFocused();

    // set effects of color sliders but don't persist to disk:
    colorWasChanged(false);
  }

  // callback:
  private void chkDiscordPrivateChanged() {
    discordPrivateWasChanged();
  }

  private void discordPrivateWasChanged(bool persist = true) {
    discordPrivate = chkDiscordPrivate.checked;

    if (!persist) return;
    save();
  }

  // callback:
  private void chkDiscordEnableChanged() {
    discordEnableWasChanged();
  }

  private void discordEnableWasChanged(bool persist = true) {
    discordEnable = chkDiscordEnable.checked;

    if (!persist) return;
    save();
  }

  // callback:
  private void chkRaceModeChanged() {
    raceModeWasChanged();
  }

  private void raceModeWasChanged(bool persist = true) {
    raceMode = chkRaceMode.checked;

    if (!persist) return;
    save();
  }

  // callback:
  private void ddlFontChanged() {
    FontIndex = ddlFont.selected.offset;

    fontWasChanged();
  }

  private void fontWasChanged(bool persist = true) {
    if (!persist) return;
    save();
  }

  // callback:
  private void txtNameChanged() {
    nameWasChanged();
  }

  private void nameWasChanged(bool persist = true) {
    local.name = txtName.text.strip();

    if (!persist) return;
    save();
  }

  // callback:
  private void chkTunicChanged() {
    syncTunic = chkTunic.checked;
    save();
  }

  // callback:
  private void chkShowMyLabelChanged() {
    showMyLabel = chkShowMyLabel.checked;
    save();
  }

  // callback:
  private void chkShowLabelsChanged() {
    showLabels = chkShowLabels.checked;
    save();
  }

  // callback:
  private void startClicked() {
    start();
    hide();
  }

  // callback:
  private void colorTextChanged() {
    player_color = parse_player_color(txtColor.text);

    setColorSliders();

    colorWasChanged();
  }

  // callback:
  private void colorSliderChanged() {
    player_color = (slRed.position & 31) |
      ((slGreen.position & 31) <<  5) |
      ((slBlue.position  & 31) << 10);

    setColorText();

    colorWasChanged();
  }

  private void colorWasChanged(bool persist = true) {
    if (local.player_color == player_color) return;

    // assign to player:
    local.player_color = player_color;

    colorCanvas.fill(player_color | 0x8000);
    colorCanvas.update();

    if (@worldMapWindow != null) {
      worldMapWindow.renderPlayers();
    }

    if (!persist) return;

    // persist settings to disk:
    save();
  }

  void start() {
    save();

    started = true;
  }

  void show() {
    ok.enabled = true;
  }

  void hide() {
    ok.enabled = false;
  }
}
