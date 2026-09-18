#ifndef UI_H
#define UI_H
typedef struct ui_screen ui_screen_t;
void ui_label(ui_screen_t *screen, const char *text);
void ui_button(ui_screen_t *screen, const char *text, void (*cb)(void));
void on_save_clicked(void);
void on_cancel_clicked(void);
#endif
