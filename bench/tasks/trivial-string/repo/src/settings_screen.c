#include "ui.h"

void settings_screen_build(ui_screen_t *screen) {
    ui_label(screen, "Settings");
    ui_button(screen, "Sav Changes", on_save_clicked);
    ui_button(screen, "Cancel", on_cancel_clicked);
}
