#include "score_engine.h"
#include <stdio.h>
#include <string.h>

static uint8_t *score_of(se_state_t *st, se_side_t s) {
    return s == SE_SIDE_RED ? &st->score_red : &st->score_blue;
}
static uint8_t *games_of(se_state_t *st, se_side_t s) {
    return s == SE_SIDE_RED ? &st->games_red : &st->games_blue;
}

static void apply_point(se_state_t *st, se_side_t side) {
    se_side_t other = (se_side_t)(1 - side);
    (*score_of(st, side))++;
    st->server = side;                                /* 得分方发球 */
    uint8_t a = *score_of(st, side), b = *score_of(st, other);
    if ((a >= 21 && a - b >= 2) || a == 30) {         /* 胜局 */
        (*games_of(st, side))++;
        if (*games_of(st, side) >= 2) { st->match_over = true; st->winner = side; }
        else {
            st->current_game++;
            st->score_red = st->score_blue = 0;
        }
    }
}

void se_init(se_state_t *st) {
    *st = (se_state_t){0};                            /* C11 复合字面量整体清零 */
    st->server = SE_SIDE_RED;                         /* 首局红方先发 */
    st->current_game = 1;
}

void se_restore(se_state_t *st, unsigned r, unsigned b, unsigned gr, unsigned gb, se_side_t server) {
    se_init(st);
    st->score_red=r;st->score_blue=b;st->games_red=gr;st->games_blue=gb;
    st->current_game=gr+gb+1;st->server=server;
    st->baseline[0]=r;st->baseline[1]=b;st->baseline[2]=gr;st->baseline[3]=gb;st->baseline[4]=server;
}

se_err_t se_score_side(se_state_t *st, se_side_t side) {
    if (st->match_over) return SE_ERR_MATCH_OVER;
    if (st->log_len >= SE_LOG_MAX) return SE_ERR_NOT_UNDOABLE;
    st->log[st->log_len++] = (uint8_t)side;
    apply_point(st, side);
    return SE_OK;
}

se_side_t se_winner(const se_state_t *st) { return st->winner; }

/* Task 5/6 实现，先占位保证编译 */
se_err_t se_score(se_state_t *st, uint16_t ring_id) {
    int side = se_ring_side(st, ring_id);
    if (side < 0) return SE_ERR_RING_INACTIVE;
    return se_score_side(st, (se_side_t)side);
}
static void rebuild(se_state_t *st) {                 /* 从日志全量重放 */
    uint8_t  keep_log[SE_LOG_MAX]; uint16_t keep_len = st->log_len;
    uint16_t keep_ring[2][2];
    for (int i = 0; i < keep_len; i++) keep_log[i] = st->log[i];
    for (int s = 0; s < 2; s++)
        for (int k = 0; k < 2; k++) keep_ring[s][k] = st->active_ring[s][k];
    se_restore(st,st->baseline[0],st->baseline[1],st->baseline[2],st->baseline[3],(se_side_t)st->baseline[4]);
    st->log_len = keep_len;
    for (int i = 0; i < keep_len; i++) st->log[i] = keep_log[i];
    for (int s = 0; s < 2; s++)
        for (int k = 0; k < 2; k++) st->active_ring[s][k] = keep_ring[s][k];
    for (uint16_t i = 0; i < keep_len; i++) apply_point(st, (se_side_t)keep_log[i]);
}

se_err_t se_undo(se_state_t *st) {
    if (st->log_len == 0) return SE_ERR_NOT_UNDOABLE;
    st->log_len--;
    rebuild(st);
    return SE_OK;
}
void se_reset_checkins(se_state_t *st) {
    for (int s = 0; s < 2; s++)
        for (int k = 0; k < 2; k++) st->active_ring[s][k] = 0;
}
se_err_t se_checkin(se_state_t *st, uint16_t ring_id, se_side_t side) {
    if (se_ring_side(st, ring_id) >= 0) return SE_ERR_DUP;
    for (int k = 0; k < 2; k++)
        if (st->active_ring[side][k] == 0) { st->active_ring[side][k] = ring_id; return SE_OK; }
    return SE_ERR_SIDE_FULL;
}
int se_ring_side(const se_state_t *st, uint16_t ring_id) {
    if (ring_id == 0) return -1;                       /* 0 为空槽哨兵 */
    for (int s = 0; s < 2; s++)
        for (int k = 0; k < 2; k++)
            if (st->active_ring[s][k] == ring_id) return s;
    return -1;
}

static const char *side_cn(se_side_t s) { return s == SE_SIDE_RED ? "红" : "蓝"; }

static uint8_t side_score(const se_state_t *st, se_side_t s) {
    return s == SE_SIDE_RED ? st->score_red : st->score_blue;
}
static uint8_t side_games(const se_state_t *st, se_side_t s) {
    return s == SE_SIDE_RED ? st->games_red : st->games_blue;
}

const char *se_announce(const se_state_t *st, char *buf, size_t cap) {
    se_side_t sv = st->server;
    int court_right = (side_score(st, sv) % 2) == 0; /* 发球方分数偶→右区 */
    snprintf(buf, cap, "%d比%d，%s方发球，%s区",
             st->score_red, st->score_blue,
             side_cn(sv), court_right ? "右" : "左");
    se_side_t lead = st->score_red >= st->score_blue ? SE_SIDE_RED : SE_SIDE_BLUE;
    uint8_t a = side_score(st, lead), b = side_score(st, (se_side_t)(1 - lead));
    size_t len = strlen(buf);
    if (a == b && a >= 20) {
        snprintf(buf + len, cap - len, "，平分");
        return buf;
    }
    if (!st->match_over && a >= 20 && a - b >= 1) {
        snprintf(buf + len, cap - len, "，%s", side_games(st, lead) >= 1 ? "场点" : "局点");
    }
    return buf;
}
