/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/*
 * Scene "sunset": a large glossy red sphere and a large glossy blue sphere on a
 * cream and teal tiled floor, under a sky that runs from orange at the horizon
 * through crimson to deep blue, lit by one distant light from the left. The
 * spheres do not reflect; they have a highlight and cast shadows.
 *
 * A scene is a file like this one; render.h includes the one named by
 * RT_SCENE_HEADER (this one by default). A scene defines:
 *   RT_NUM_SPHERES, rt_spheres[]        the spheres (RT_SPHERE in render.h)
 *   RT_TILE_LIGHT, RT_TILE_DARK         floor colors; RT_TILE_SHIFT is the log2
 *                                       of the tile size in fixed-point units
 *   RT_SKY_HORIZON, RT_SKY_ZENITH       sky colors; RT_SKY_MIDDLE (optional,
 *                                       with RT_SKY_THREE_STOPS 1) a third stop
 *   RT_SKY_GLOW                         1 for a glow around the light
 *   RT_FLOOR_REFLECT, RT_AMBIENT, RT_FOG_DISTANCE, RT_MAX_BOUNCES
 *   RT_EYE, RT_LOOK_AT, RT_LIGHT_DIR    camera and light
 */

#ifndef RAYTRACE_SCENE_SUNSET_INC
#define RAYTRACE_SCENE_SUNSET_INC

#define RT_NUM_SPHERES 2
#define RT_MAX_BOUNCES 2

static const sphere_t rt_spheres[RT_NUM_SPHERES] = {
    /* Large red sphere on the left. */
    RT_SPHERE(-1.9, 1.5, 0.0, 1.5, 0.85, 0.04, 0.03, 0.0, 0.9),
    /* Large blue sphere on the right, a little further back. */
    RT_SPHERE(2.1, 1.5, 1.2, 1.5, 0.05, 0.45, 0.75, 0.0, 0.9),
};

#define RT_TILE_LIGHT v3(FX(0.92), FX(0.80), FX(0.55))
#define RT_TILE_DARK v3(FX(0.02), FX(0.22), FX(0.30))
#define RT_TILE_SHIFT 17 /* tiles two units wide */

#define RT_SKY_THREE_STOPS 1
#define RT_SKY_HORIZON v3(FX(1.0), FX(0.50), FX(0.10))
#define RT_SKY_MIDDLE v3(FX(0.60), FX(0.10), FX(0.25))
#define RT_SKY_ZENITH v3(FX(0.03), FX(0.03), FX(0.22))
#define RT_SKY_GLOW 1

#define RT_FLOOR_REFLECT FX(0.10)
#define RT_AMBIENT FX(0.30)
#define RT_FOG_DISTANCE FX(40.0)

#define RT_EYE v3(FX(0.0), FX(2.1), FX(-7.5))
#define RT_LOOK_AT v3(FX(0.0), FX(1.3), FX(0.0))
#define RT_LIGHT_DIR v3(FX(-0.8), FX(0.6), FX(-0.25))

#endif /* RAYTRACE_SCENE_SUNSET_INC */
