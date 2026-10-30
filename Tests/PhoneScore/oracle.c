#include "score_engine.h"
#include <stdio.h>
int main(void) {
    se_state_t s; se_init(&s);
    const char *ops="rrrrrrrrrrrrrrrrrrrrbbbbbbbbbbbbbbbbbbbbrrrrbUbbrbrbrbrbrbrbrbrbrbbbbbbbbbbbbbbbbbbbbbUUrr";
    for (const char *p=ops; *p; ++p) {
        se_err_t e=*p=='U'?se_undo(&s):se_score_side(&s,*p=='r'?SE_SIDE_RED:SE_SIDE_BLUE);
        if(e==SE_OK) printf("%c,%d,%d,%d,%d,%d,%d\n",*p,s.score_red,s.score_blue,s.games_red,s.games_blue,s.server,s.match_over);
    }
    return 0;
}
