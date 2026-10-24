#include <SDL2/SDL.h>
#include <stdio.h>
#include <verilated.h>

#include "Vtop_audio.h"

// Parameters
// screen dimensions: VGA picture on top, seven-segment display below
const int H_RES = 800;
const int V_RES = 600;
const int SEG_H = 160;
// frequencies
const int  CLK_AUDIO_HZ    = 49'158'650;
const int  PWM_PERIOD_CLKS = 1024;
const int  PWM_HZ          = CLK_AUDIO_HZ / PWM_PERIOD_CLKS;   // 48.006 kHz
// both clocks come from one MMCM: clk_audio = VCO/13, pixel_clk = VCO/16,
// so there are exactly 13 pixel_clk cycles per 16 clk_audio cycles
const int PIX_PER_AUDIO_NUM = 13;
const int PIX_PER_AUDIO_DEN = 16;
// sizes
const int BUFFER_SIZE  = 64;
const int RENDER_CYCLE = 1'500'000;
// max sound waiting in the SDL queue: 40 ms (more than one device buffer of 1024 samples = 21 ms)
const Uint32 MAX_QUEUED_BYTES = PWM_HZ * 40 / 1000 * sizeof(float);

// Functions
// detecting key press
bool pressed(bool now, bool& prev) {
    bool pres = now && !prev;
    prev = now;
    return pres;
}

typedef struct Pixel {  // for SDL texture, SDL_PIXELFORMAT_RGBA8888
  uint8_t a;  // transparency
  uint8_t b;  // blue
  uint8_t g;  // green
  uint8_t r;  // red
} Pixel;

// 7‑segment display rendering into the area (x0, y0, ww, wh) of the window
void render_7seg(SDL_Renderer* ren, const Uint8* segs, const Uint8* dps, int n,
                 int ax, int ay, int ww, int wh) {
  SDL_Rect area = {ax, ay, ww, wh};
  SDL_SetRenderDrawColor(ren, 20, 20, 25, 255);         // black background
  SDL_RenderFillRect(ren, &area);

  // parameters for rendering numbers
  const int dw  = 60;     // digit width
  const int dh  = 120;    // digit height
  const int gap = 18;     // gap between digits
  const int t   = 8;      // segment width
  const int total_w = n * dw + (n - 1) * gap;     // overall width

  //upper left corner of the row
  const int x0 = ax + (ww - total_w) / 2;
  const int y0 = ay + (wh - dh) / 2;

  SDL_Color on  = {255, 60, 60, 255};   // bright red
  SDL_Color off = {60, 25, 25, 255};    // dark red

  for (int d = 0; d < n; ++d) {
    int x = x0 + d * (dw + gap);
    int y = y0;

    SDL_Rect r[8] = {
        { x + t,       y,             dw - 2*t, t        },   // a        --a--
        { x + dw - t,  y + t,         t,        dh/2 - t },   // b        |   |
        { x + dw - t,  y + dh/2,      t,        dh/2 - t },   // c        f   b
        { x + t,       y + dh - t,    dw - 2*t, t        },   // d        |   |
        { x,           y + dh/2,      t,        dh/2 - t },   // e        --g--
        { x,           y + t,         t,        dh/2 - t },   // f        |   |
        { x + t,       y + dh/2-t/2,  dw - 2*t, t        },   // g        e   c
        { x + dw + 4,  y + dh - t,    t,        t        },   // dp       |   |
    };                                                        //          --d-- .dp
    // draw a segment
    for (int bit = 0; bit < 7; ++bit) {
      SDL_Color c = ((segs[d] >> bit) & 1) == 0 ? on : off;
      SDL_SetRenderDrawColor(ren, c.r, c.g, c.b, c.a);
      SDL_RenderFillRect(ren, &r[bit]);
    }
    // draw dp
    SDL_Color cp = ( dps[d] == 0 )? on : off;
    SDL_SetRenderDrawColor(ren, cp.r, cp.g, cp.b, cp.a);
    SDL_RenderFillRect(ren, &r[7]);
  }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) < 0) {
    printf("SDL init failed: %s\n", SDL_GetError());
    return 1;
  }

  SDL_Window*   sdl_window   = NULL;
  SDL_Renderer* sdl_renderer = NULL;

  sdl_window = SDL_CreateWindow("audio_nexys_a7", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                H_RES, V_RES + SEG_H, SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
  if (!sdl_window) {
    printf("Window creation failed: %s\n", SDL_GetError());
    return 1;
  }

  // no PRESENTVSYNC: waiting for the monitor would slow down the simulation and break the sound
  sdl_renderer = SDL_CreateRenderer(sdl_window, -1, SDL_RENDERER_ACCELERATED);
  if (!sdl_renderer) {
    printf("Renderer creation failed: %s\n", SDL_GetError());
    return 1;
  }
  SDL_RenderSetLogicalSize(sdl_renderer, H_RES, V_RES + SEG_H);   // keep proportions when resized

  SDL_Texture* sdl_texture = SDL_CreateTexture(sdl_renderer, SDL_PIXELFORMAT_RGBA8888,
                                               SDL_TEXTUREACCESS_STREAMING, H_RES, V_RES);
  if (!sdl_texture) {
    printf("Texture creation failed: %s\n", SDL_GetError());
    return 1;
  }
  static Pixel screenbuffer[H_RES * V_RES];

  SDL_AudioSpec want{}, have{};
  want.freq     = PWM_HZ;
  want.format   = AUDIO_F32SYS;
  want.channels = 1;
  want.samples  = PWM_PERIOD_CLKS;          // 1024   
  want.callback = NULL;                

  SDL_AudioDeviceID sdl_audio = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);

  if (sdl_audio) {
    printf("Audio: %d Hz\n", have.freq);
    SDL_PauseAudioDevice(sdl_audio, 0);
  } else {
    printf("Audio open failed: %s\n", SDL_GetError());
  }

  // reference SDL keyboard state array: https://wiki.libsdl.org/SDL_GetKeyboardState
  const Uint8 *keyb_state = SDL_GetKeyboardState(NULL);

  // initialize Verilog module
  Vtop_audio* top = new Vtop_audio;

  // reset: one edge of each clock
  top->sim_rst   = 1;
  top->clk       = 0;
  top->pixel_clk = 0;
  top->eval();
  top->clk       = 1;
  top->pixel_clk = 1;
  top->eval();
  top->sim_rst   = 0;
  top->clk       = 0;
  top->pixel_clk = 0;
  top->eval();
 
  top->button_c = 0;
  top->button_u = 0;
  top->button_d = 0;
  top->button_l = 0;
  top->button_r = 0;
  
  top->sw0 = 0;
  top->sw1 = 0;
  top->sw2 = 0;

  // main loop
  bool prev_c = false;
  bool prev_u = false;
  bool prev_d = false;
  bool prev_l = false;
  bool prev_r = false;

  bool prev_oct[8] = {false};

  int pwm_high  = 0;      // 
  int pwm_ticks = 0;

  Uint8 segs[8];
  Uint8 dps[8];
  for (int i = 0; i < 8; i++) { 
    segs[i] = 0x7F; dps[i] = 1; 
  }

  int  cur_oct    = 0;
  int  render_acc = 0;
  bool quit       = false;

  // buffer for push in SDL
  float buff[BUFFER_SIZE];
  int   buff_n = 0;

  int       pix_phase   = 0;
  bool      vga_on      = true;   // 'V' freezes the VGA picture if the sim is too slow for sound
  bool      prev_v      = false;
  bool      audio_on    = true;   // 'A' stops clk (the whole sound path) to debug the picture faster
  bool      prev_a      = false;
  long long step        = 0;
  long long last_step   = 0;
  Uint64    last_ticks  = SDL_GetPerformanceCounter();
  double    sim_speed   = 0.0;    // fraction of real time
  while (!quit) {
    // one step = one clk_audio period; pixel_clk ticks 13 times per 16 steps
    // (one eval for both clocks is faster; the domains don't talk to each other in the sim)
    bool aud_tick = audio_on;
    bool pix_tick = false;
    if (vga_on) {
      pix_phase += PIX_PER_AUDIO_NUM;
      if (pix_phase >= PIX_PER_AUDIO_DEN) {
        pix_phase -= PIX_PER_AUDIO_DEN;
        pix_tick   = true;
      }
    }
    if (aud_tick || pix_tick) {
      top->clk       = aud_tick;
      top->pixel_clk = pix_tick;
      top->eval();
      top->clk       = 0;
      top->pixel_clk = 0;
      top->eval();
    }

    if (pix_tick) {
      // store the pixel if it is in the visible area
      if (top->sdl_de && top->sdl_sx < H_RES && top->sdl_sy < V_RES) {
        Pixel* p = &screenbuffer[top->sdl_sy * H_RES + top->sdl_sx];
        p->a = 0xFF;
        p->r = top->sdl_r * 17;   // 4 bit -> 8 bit: 0xF * 17 = 0xFF
        p->g = top->sdl_g * 17;
        p->b = top->sdl_b * 17;
      }
    }

    // updating button state ~26 mc
    if ((step & 0x1FFFF) == 0) {
      SDL_PumpEvents();
      SDL_Event e;
      while (SDL_PollEvent(&e)) {
        if (e.type == SDL_QUIT || (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_q) ) 
          quit = true;
      }
      for (int d = 0; d < 8; d++) {
        if (pressed(keyb_state[SDL_SCANCODE_1 + d], prev_oct[d])) {
          cur_oct = d;
          break;
        }
      }
      top->sw0 = (cur_oct >> 0) & 1;
      top->sw1 = (cur_oct >> 1) & 1;
      top->sw2 = (cur_oct >> 2) & 1;

      if (pressed(keyb_state[SDL_SCANCODE_V], prev_v)) vga_on   = !vga_on;
      if (pressed(keyb_state[SDL_SCANCODE_A], prev_a)) audio_on = !audio_on;
      if (pressed(keyb_state[SDL_SCANCODE_SPACE], prev_c)) top->button_c = 1;
      if (pressed(keyb_state[SDL_SCANCODE_UP],    prev_u)) top->button_u = 1;
      if (pressed(keyb_state[SDL_SCANCODE_DOWN],  prev_d)) top->button_d = 1;
      if (pressed(keyb_state[SDL_SCANCODE_LEFT],  prev_l)) top->button_l = 1;
      if (pressed(keyb_state[SDL_SCANCODE_RIGHT], prev_r)) top->button_r = 1;

      Uint64 ticks = SDL_GetPerformanceCounter();
      double secs  = (double)(ticks - last_ticks) / SDL_GetPerformanceFrequency();
      if (secs > 0.5) {
        sim_speed  = (double)(step - last_step) / CLK_AUDIO_HZ / secs;
        last_ticks = ticks;
        last_step  = step;
      }

      char title[160];
      snprintf(title, sizeof(title), "play=%d, volume=%d, sim speed %.0f%% of real time%s%s",
              (int)top->play, (int)top->volume, sim_speed * 100.0,
              vga_on ? "" : ", VGA off (V)", audio_on ? "" : ", audio off (A)");
      SDL_SetWindowTitle(sdl_window, title);
    }
    if ((step & 0x1FFFF) == 1) {
      top->button_c = 0;
      top->button_u = 0;
      top->button_d = 0;
      top->button_l = 0;
      top->button_r = 0;
    }

    // the seven-segment display and the sound are in the clk domain: nothing changes without its tick
    if (aud_tick) {
      // sampling of seven‑segment display
      for (int i = 0; i < 8; ++i) {
        if (((top->anodes >> i) & 1) == 0) {
          segs[7 - i] = (Uint8)(top->seg_active_n);
          dps [7 - i] = (Uint8)(top->dp_n);   // active low, like the segments
          break;
        }
      }

      //PWM demodulation
      if (top->aud_pwm) 
        pwm_high++;
      if (++pwm_ticks >= PWM_PERIOD_CLKS) {
        float duty   = (float)pwm_high / (float)pwm_ticks;  
        float dc     = (float)top->volume / 32.0f;          // constant of displacement
        float sample = (duty - dc) * 2.0f;

        if (!top->aud_en) sample = 0.0f;

        buff[buff_n++] = sample * 0.1f;

        if (buff_n >= BUFFER_SIZE) {
          if (sdl_audio) {
            SDL_QueueAudio(sdl_audio, buff, buff_n * sizeof(float));  // internal SDL buffer
            // if the sim is faster than real time, wait for the sound card: otherwise the queue grows
            // and every button press is heard later and later
            while (SDL_GetQueuedAudioSize(sdl_audio) > MAX_QUEUED_BYTES)
              SDL_Delay(1);
          }
          buff_n = 0;
        }

        pwm_high = 0;
        pwm_ticks = 0;
      }
    }

    // rendering every 30 ms
    if (++render_acc >= RENDER_CYCLE) {
      SDL_UpdateTexture(sdl_texture, NULL, screenbuffer, H_RES * sizeof(Pixel));
      SDL_RenderClear(sdl_renderer);
      SDL_Rect vga_area = {0, 0, H_RES, V_RES};
      SDL_RenderCopy(sdl_renderer, sdl_texture, NULL, &vga_area);
      render_7seg(sdl_renderer, segs, dps, 8, 0, V_RES, H_RES, SEG_H);
      SDL_RenderPresent(sdl_renderer);   // frame display
      render_acc = 0;
    }

    step++;
    }

  top->final();   // simulation done
  
  SDL_DestroyTexture(sdl_texture);
  SDL_DestroyRenderer(sdl_renderer);
  SDL_DestroyWindow(sdl_window);
  SDL_CloseAudioDevice(sdl_audio);
  SDL_Quit();

  return 0;
}