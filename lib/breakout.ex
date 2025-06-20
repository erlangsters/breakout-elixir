defmodule Breakout do
  @width 800
  @height 600
  @paddle_width 100
  @paddle_height 20
  @ball_size 15
  @brick_width 80
  @brick_height 30
  @brick_rows 5
  @brick_cols 10

  @vertex_shader_src """
  #version 460 core
  layout(location = 0) in vec2 aPos;
  uniform mat4 projection;
  uniform mat4 model;
  void main() {
      gl_Position = projection * model * vec4(aPos, 0.0, 1.0);
  }
  """

  @fragment_shader_src """
  #version 460 core
  out vec4 FragColor;
  uniform vec3 color;
  void main() {
      FragColor = vec4(color, 1.0);
  }
  """

  defmodule GameState do
    defstruct [
      :window,
      :shader_program,
      :vao,
      :vbo,
      :projection,
      paddle_pos: 0.0,
      ball_pos: {0.0, 0.0},
      ball_vel: {0.0, 0.0},
      bricks: [],
      lives: 3,
      score: 0,
      game_over: false,
      game_won: false
    ]
  end

  def start do
    # Initialize GLFW
    :glfw.init()

    {:ok, window} = :glfw.create_window(@width, @height, "Breakout")

    # Set up EGL
    display = :egl.get_display(:default_display)
    {:ok, _} = :egl.initialize(display)
    :egl.bind_api(:opengl_api)

    config_attribs = [
      surface_type: [:window_bit],
      renderable_type: [:opengl_bit]
    ]

    {:ok, [config | _]} = :egl.choose_config(display, config_attribs)

    context_attribs = [context_major_version: 3]
    {:ok, context} = :egl.create_context(display, config, :no_context, context_attribs)

    window_handle = :glfw.window_egl_handle(window)
    {:ok, surface} = :egl.create_window_surface(display, config, window_handle, [])
    :ok = :egl.make_current(display, surface, surface, context)

    # Set up OpenGL
    :gl.viewport(0, 0, @width, @height)

    # Compile shaders
    {:ok, vertex_shader} = :gl.create_shader(:vertex_shader)
    :gl.shader_source(vertex_shader, [@vertex_shader_src])
    :gl.compile_shader(vertex_shader)

    {:ok, fragment_shader} = :gl.create_shader(:fragment_shader)
    :gl.shader_source(fragment_shader, [@fragment_shader_src])
    :gl.compile_shader(fragment_shader)

    {:ok, shader_program} = :gl.create_program()
    :gl.attach_shader(shader_program, vertex_shader)
    :gl.attach_shader(shader_program, fragment_shader)
    :gl.link_program(shader_program)

    :gl.delete_shader(vertex_shader)
    :gl.delete_shader(fragment_shader)

    # Set up vertex data
    {:ok, [vao]} = :gl.gen_vertex_arrays(1)
    {:ok, [vbo]} = :gl.gen_buffers(1)

    :gl.bind_vertex_array(vao)
    :gl.bind_buffer(:array_buffer, vbo)

    # Simple quad vertices (x, y)
    vertices = [
      -0.5, -0.5,
       0.5, -0.5,
       0.5,  0.5,
      -0.5,  0.5
    ]

    vertices_bin = for x <- vertices, into: <<>>, do: <<x::32-float-little>>
    :gl.buffer_data(:array_buffer, length(vertices) * 4, vertices_bin, :static_draw)

    :gl.vertex_attrib_pointer(0, 2, :float, false, 2 * 4, 0)
    :gl.enable_vertex_attrib_array(0)

    :gl.bind_buffer(:array_buffer, 0)
    :gl.bind_vertex_array(0)

    # Create projection matrix
    projection = create_ortho_matrix(0.0, @width, @height, 0.0, -1.0, 1.0)

    # Initialize game state
    initial_state = %GameState{
      window: window,
      shader_program: shader_program,
      vao: vao,
      vbo: vbo,
      projection: projection,
      ball_pos: {@width / 2, @height / 2},
      ball_vel: {200.0, -200.0},
      bricks: generate_bricks()
    }

    # Set up input handlers
    :glfw.set_key_handler(window, self())

    # Start game loop
    game_loop(display, surface, initial_state)

    # Clean up
    :glfw.destroy_window(window)
    :glfw.terminate()
    :ok
  end

  defp game_loop(display, surface, state) do
    case :glfw.window_should_close(state.window) do
      true -> :ok
      false ->
        # Process input
        new_state = handle_input(state)

        # Update game state
        updated_state = update_game(new_state)

        # Render
        render_game(updated_state)
        :egl.swap_buffers(display, surface)

        # Handle events
        :glfw.poll_events()
        handle_events(state.window)

        # Continue loop
        Process.sleep(16)  # ~60 FPS
        game_loop(display, surface, updated_state)
    end
  end

  defp handle_input(state) do
    window = state.window
    case :glfw.get_key(window, :glfw.KEY_LEFT) do
      :glfw.PRESS ->
        new_pos = max(state.paddle_pos - 10.0, 0.0)
        %{state | paddle_pos: new_pos}
      _ ->
        case :glfw.get_key(window, :glfw.KEY_RIGHT) do
          :glfw.PRESS ->
            new_pos = min(state.paddle_pos + 10.0, @width - @paddle_width)
            %{state | paddle_pos: new_pos}
          _ -> state
        end
    end
  end

  defp update_game(%{game_over: true}), do: state
  defp update_game(%{game_won: true}), do: state
  defp update_game(state) do
    {ball_x, ball_y} = state.ball_pos
    {vel_x, vel_y} = state.ball_vel

    # Update ball position
    new_ball_x = ball_x + vel_x * 0.016  # 16ms frame time
    new_ball_y = ball_y + vel_y * 0.016

    # Check collisions with walls
    {new_vel_x, new_vel_y} = case {new_ball_x, new_ball_y} do
      {x, _} when x < 0 -> {-vel_x, vel_y}
      {x, _} when x > @width - @ball_size -> {-vel_x, vel_y}
      {_, y} when y < 0 -> {vel_x, -vel_y}
      {_, y} when y > @height ->
        # Ball fell out of screen
        new_lives = state.lives - 1
        case new_lives do
          0 -> %{state | game_over: true}
          _ -> %{state |
            ball_pos: {@width / 2, @height / 2},
            ball_vel: {200.0, -200.0},
            lives: new_lives
          }
        end
      _ -> {vel_x, vel_y}
    end

    # Check collision with paddle
    paddle_left = state.paddle_pos
    paddle_right = paddle_left + @paddle_width
    paddle_top = @height - @paddle_height

    {new_vel_x2, new_vel_y2} =
      if new_ball_y + @ball_size >= paddle_top and
         new_ball_x + @ball_size >= paddle_left and
         new_ball_x <= paddle_right do
        # Calculate reflection angle based on where ball hits paddle
        hit_pos = (new_ball_x + @ball_size/2 - paddle_left) / @paddle_width
        angle = (hit_pos - 0.5) * 1.5  # -0.75 to 0.75 radians
        speed = :math.sqrt(vel_x*vel_x + vel_y*vel_y)
        new_vel_x2 = speed * :math.sin(angle)
        new_vel_y2 = -speed * :math.cos(angle)
        {new_vel_x2, new_vel_y2}
      else
        {new_vel_x, new_vel_y}
      end

    # Check collision with bricks
    {new_bricks, new_score, {final_vel_x, final_vel_y}} =
      check_brick_collisions(state.bricks, state.score, {new_ball_x, new_ball_y}, {new_vel_x2, new_vel_y2})

    # Check if all bricks are destroyed
    game_won = new_bricks == []

    %{state |
      ball_pos: {new_ball_x, new_ball_y},
      ball_vel: {final_vel_x, final_vel_y},
      bricks: new_bricks,
      score: new_score,
      game_won: game_won
    }
  end

  defp check_brick_collisions(bricks, score, ball_pos, ball_vel) do
    {bx, by} = ball_pos
    {vx, vy} = ball_vel
    check_brick_collisions(bricks, score, ball_pos, ball_vel, [], 0)
  end

  defp check_brick_collisions([], score, _, vel, new_bricks, _hits) do
    {Enum.reverse(new_bricks), score, vel}
  end

  defp check_brick_collisions([{x, y, active} | rest], score, {bx, by}, {vx, vy}, acc, hits) do
    if active and
       bx + @ball_size >= x and bx <= x + @brick_width and
       by + @ball_size >= y and by <= y + @brick_height do
      # Collision detected - simple reflection (reverse Y velocity)
      check_brick_collisions(rest, score + 10, {bx, by}, {vx, -vy},
                           [{x, y, false} | acc], hits + 1)
    else
      check_brick_collisions(rest, score, {bx, by}, {vx, vy},
                           [{x, y, active} | acc], hits)
    end
  end

  defp render_game(state) do
    :gl.clear_color(0.0, 0.0, 0.0, 1.0)
    :gl.clear([:color_buffer_bit])

    :gl.use_program(state.shader_program)
    :gl.uniform_matrix4fv(:gl.get_uniform_location(state.shader_program, "projection"),
                         1, false, state.projection)

    :gl.bind_vertex_array(state.vao)

    # Draw paddle
    model = create_model_matrix(state.paddle_pos, @height - @paddle_height,
                              @paddle_width, @paddle_height)
    :gl.uniform_matrix4fv(:gl.get_uniform_location(state.shader_program, "model"),
                         1, false, model)
    :gl.uniform3f(:gl.get_uniform_location(state.shader_program, "color"),
                 1.0, 1.0, 1.0)
    :gl.draw_arrays(:triangle_fan, 0, 4)

    # Draw ball
    {ball_x, ball_y} = state.ball_pos
    model_ball = create_model_matrix(ball_x, ball_y, @ball_size, @ball_size)
    :gl.uniform_matrix4fv(:gl.get_uniform_location(state.shader_program, "model"),
                         1, false, model_ball)
    :gl.uniform3f(:gl.get_uniform_location(state.shader_program, "color"),
                 1.0, 0.0, 0.0)
    :gl.draw_arrays(:triangle_fan, 0, 4)

    # Draw bricks
    Enum.each(state.bricks, fn {x, y, active} ->
      if active do
        model_brick = create_model_matrix(x, y, @brick_width, @brick_height)
        :gl.uniform_matrix4fv(:gl.get_uniform_location(state.shader_program, "model"),
                             1, false, model_brick)
        :gl.uniform3f(:gl.get_uniform_location(state.shader_program, "color"),
                     0.0, 0.0, 1.0)
        :gl.draw_arrays(:triangle_fan, 0, 4)
      end
    end)

    # Draw game over or win message (would need text rendering)
    cond do
      state.game_over -> :ok
      state.game_won -> :ok
      true -> :ok
    end

    :gl.bind_vertex_array(0)
  end

  # Helper functions
  defp generate_bricks do
    padding = 5
    offset_top = 50
    offset_left = (@width - (@brick_cols * (@brick_width + padding))) / 2

    for row <- 0..(@brick_rows-1), col <- 0..(@brick_cols-1) do
      x = offset_left + (col * (@brick_width + padding))
      y = offset_top + (row * (@brick_height + padding))
      {x, y, true}
    end
  end

  defp create_model_matrix(x, y, width, height) do
    [
      width, 0.0, 0.0, x + width/2,
      0.0, height, 0.0, y + height/2,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ]
  end

  defp create_ortho_matrix(left, right, bottom, top, near, far) do
    [
      2.0/(right-left), 0.0, 0.0, -(right+left)/(right-left),
      0.0, 2.0/(top-bottom), 0.0, -(top+bottom)/(top-bottom),
      0.0, 0.0, -2.0/(far-near), -(far+near)/(far-near),
      0.0, 0.0, 0.0, 1.0
    ]
  end

  defp handle_events(window) do
    receive do
      %{window: ^window, key: :glfw.KEY_ESCAPE, action: :glfw.PRESS} ->
        :glfw.set_window_should_close(window, true)
      _ ->
        :ok
    after 0 ->
      :ok
    end
  end
end