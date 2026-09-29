/* CPU adapter for the MikkTSpace reference implementation. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <setjmp.h>
#include <assert.h>

/* All jumps stay inside this C call, across C frames only. */
typedef union Allocation Allocation;
union Allocation {
    max_align_t alignment;
    struct { Allocation *next, *previous; size_t size; } value;
};
typedef struct {
    jmp_buf escape;
    Allocation *head;
    size_t used, capacity;
    uint64_t iterations;
    unsigned depth;
} Budget;
#if defined(_MSC_VER)
static __declspec(thread) Budget *active_budget;
#else
static _Thread_local Budget *active_budget;
#endif
static void fg_mikk_step(void) {
    if (active_budget->iterations == 0) longjmp(active_budget->escape, 2);
    --active_budget->iterations;
}
static void fg_mikk_enter(void) {
    if (++active_budget->depth > 256) longjmp(active_budget->escape, 2);
}
static void fg_mikk_leave(void) { --active_budget->depth; }
static void *bounded_malloc(size_t size) {
    Budget *b = active_budget;
    if (size > b->capacity - b->used || sizeof(Allocation) > b->capacity - b->used - size)
        longjmp(b->escape, 2);
    Allocation *a = (Allocation *)malloc(sizeof(Allocation) + size);
    if (!a) longjmp(b->escape, 2);
    a->value.size = sizeof(Allocation) + size;
    a->value.previous = NULL;
    a->value.next = b->head;
    if (b->head) b->head->value.previous = a;
    b->head = a;
    b->used += a->value.size;
    return a + 1;
}
static void bounded_free(void *ptr) {
    if (!ptr) return;
    Allocation *a = ((Allocation *)ptr) - 1;
    Budget *b = active_budget;
    if (a->value.previous) a->value.previous->value.next = a->value.next;
    else b->head = a->value.next;
    if (a->value.next) a->value.next->value.previous = a->value.previous;
    b->used -= a->value.size;
    free(a);
}
#define malloc bounded_malloc
#define free bounded_free
/* Reference assertions must report an error, never terminate the host. */
#undef assert
#define assert(condition) ((condition) ? (void)0 : (void)longjmp(active_budget->escape, 4))
#define genTangSpaceDefault fg_mikk_default
#define genTangSpace fg_mikk_generate
#include "../vendor/mikktspace/mikktspace.c"
#undef malloc
#undef free

typedef struct {
    const float *positions, *normals, *uvs;
    const uint32_t *indices;
    uint32_t corners;
    float *output;
} Mesh;
static Mesh *mesh(const SMikkTSpaceContext *c) { return (Mesh *)c->m_pUserData; }
static int faces(const SMikkTSpaceContext *c) { return (int)(mesh(c)->corners / 3); }
static int vertices(const SMikkTSpaceContext *c, int f) { (void)c; (void)f; return 3; }
static uint32_t vertex(const SMikkTSpaceContext *c, int f, int v) { return mesh(c)->indices[f * 3 + v]; }
static void position(const SMikkTSpaceContext *c, float *out, int f, int v) {
    memcpy(out, mesh(c)->positions + vertex(c,f,v) * 3, 3 * sizeof(float));
}
static void normal(const SMikkTSpaceContext *c, float *out, int f, int v) {
    const float *n = mesh(c)->normals + vertex(c,f,v) * 3;
    const double length = sqrt((double)n[0]*n[0] + (double)n[1]*n[1] + (double)n[2]*n[2]);
    for (int i=0; i<3; ++i) out[i] = (float)(n[i] / length);
}
static void uv(const SMikkTSpaceContext *c, float *out, int f, int v) {
    memcpy(out, mesh(c)->uvs + vertex(c,f,v) * 2, 2 * sizeof(float));
}
static void tangent(const SMikkTSpaceContext *c, const float *t, float sign, int f, int v) {
    float *out = mesh(c)->output + (f * 3 + v) * 4;
    memcpy(out, t, 3 * sizeof(float));
    out[3] = sign;
}
static int execute(Budget *budget, Mesh *input) {
    SMikkTSpaceInterface api = {faces, vertices, position, normal, uv, tangent, NULL};
    SMikkTSpaceContext context = {&api, input};
    const int failure = setjmp(budget->escape);
    if (failure) return failure;
    return fg_mikk_default(&context) ? 0 : 1;
}
/* Called only after Rust validates buffer lengths, coordinates and limits. */
int fg_mikk_bounded(const float *positions, const float *normals, const float *uvs,
                    const uint32_t *indices, uint32_t corners, float *output,
                    size_t scratch_bytes, uint64_t iterations) {
    Budget budget = {0};
    budget.capacity = scratch_bytes;
    budget.iterations = iterations;
    Budget *previous = active_budget;
    active_budget = &budget;
    Mesh input = {positions, normals, uvs, indices, corners, output};
    const int status = execute(&budget, &input);
    while (budget.head) bounded_free(budget.head + 1);
    active_budget = previous;
    return status;
}
