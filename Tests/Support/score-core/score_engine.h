#ifndef SCORE_ENGINE_H
#define SCORE_ENGINE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum { SE_SIDE_RED = 0, SE_SIDE_BLUE = 1 } se_side_t;
typedef enum {
    SE_OK = 0, SE_ERR_RING_INACTIVE, SE_ERR_NOT_UNDOABLE,
    SE_ERR_MATCH_OVER, SE_ERR_SIDE_FULL, SE_ERR_DUP
} se_err_t;

#define SE_LOG_MAX 256

typedef struct {
    uint8_t  games_red, games_blue;   /* 局分（三局两胜） */
    uint8_t  score_red, score_blue;   /* 当前局比分 */
    se_side_t server;                 /* 当前发球方 */
    uint8_t  current_game;            /* 1..3 */
    bool     match_over;
    se_side_t winner;
    /* 事件日志（undo 用）与报到映射：内部细节，外部勿直接改 */
    uint8_t baseline[5]; /* restored points, games, server; undo starts here */
    uint8_t  log[SE_LOG_MAX];         /* 每项记得分方 0/1 */
    uint16_t log_len;
    uint16_t active_ring[2][2];       /* [side][slot] 的 ring_id，0=空 */
} se_state_t;

void      se_init(se_state_t *st);
void      se_restore(se_state_t *st, unsigned r, unsigned b, unsigned gr, unsigned gb, se_side_t server);
se_err_t  se_score_side(se_state_t *st, se_side_t side);
se_err_t  se_score(se_state_t *st, uint16_t ring_id);
se_err_t  se_undo(se_state_t *st);
void      se_reset_checkins(se_state_t *st);
se_err_t  se_checkin(se_state_t *st, uint16_t ring_id, se_side_t side);
int       se_ring_side(const se_state_t *st, uint16_t ring_id); /* -1 未激活 */
se_side_t se_winner(const se_state_t *st);
const char *se_announce(const se_state_t *st, char *buf, size_t cap);
#endif
