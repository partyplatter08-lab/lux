defmodule Lux.Prisms.Telegram.Group.ManageGroupTest do
  use UnitAPICase, async: true

  alias Lux.Prisms.Telegram.Group.ManageGroup

  @chat_id -100_123_456
  @user_id 987_654
  @agent_ctx %{name: "ModerationAgent"}

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "handler/2" do
    test "returns a dry-run plan by default" do
      assert {:ok, result} =
               ManageGroup.handler(
                 %{
                   action: "restrict_member",
                   chat_id: @chat_id,
                   user_id: @user_id,
                   permission_template: "read_only"
                 },
                 @agent_ctx
               )

      assert result.planned == true
      assert result.executed == false
      assert result.action == :restrict_member
      assert result.category == :member_management
      assert [%{path: "/restrictChatMember"}] = result.requests
    end

    test "executes a planned Telegram request when execute is true" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path =~ "/setChatPermissions"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)
        assert decoded_body["chat_id"] == @chat_id
        assert decoded_body["permissions"]["can_send_messages"] == true
        assert decoded_body["permissions"]["can_add_web_page_previews"] == false

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, result} =
               ManageGroup.handler(
                 %{
                   action: :set_permissions,
                   chat_id: @chat_id,
                   permission_template: :no_links,
                   execute: true
                 },
                 @agent_ctx
               )

      assert result.planned == true
      assert result.executed == true
      assert result.request_count == 1
      assert [%{response: %{"result" => true}}] = result.results
    end

    test "executes with string truthy values and ignores nil execution options" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path =~ "/unbanChatMember"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)
        assert decoded_body["only_if_banned"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, result} =
               ManageGroup.handler(
                 %{
                   action: "unban_member",
                   chat_id: @chat_id,
                   user_id: @user_id,
                   only_if_banned: true,
                   execute: "1",
                   plug: nil
                 },
                 @agent_ctx
               )

      assert result.executed == true
      assert [%{request: %{path: "/unbanChatMember"}}] = result.results
    end

    test "returns execution errors from the Telegram client" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.request_path =~ "/banChatMember"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"description" => "Forbidden"}))
      end)

      assert {:error, message} =
               ManageGroup.handler(
                 %{
                   action: :ban_member,
                   chat_id: @chat_id,
                   user_id: @user_id,
                   execute: true,
                   token: "test-token"
                 },
                 @agent_ctx
               )

      assert message =~ "Failed to execute Telegram group action"
      assert message =~ "Forbidden"
    end

    test "builds moderation plans for flagged content" do
      assert {:ok, result} =
               ManageGroup.handler(
                 %{
                   action: :moderate_message,
                   chat_id: @chat_id,
                   user_id: @user_id,
                   message_id: 55,
                   text: "Join https://spam.example now",
                   policy: %{block_links: true},
                   moderation_action: :ban_member
                 },
                 @agent_ctx
               )

      assert result.status == :flagged
      assert result.moderation_action == :ban_member
      assert Enum.map(result.requests, & &1.path) == ["/deleteMessage", "/banChatMember"]
    end

    test "validates required action and parameters" do
      assert {:error, "Missing or invalid action"} = ManageGroup.handler(%{}, @agent_ctx)
      assert {:error, "Missing or invalid action"} = ManageGroup.handler(nil, @agent_ctx)

      assert {:error, "Missing or invalid user_id"} =
               ManageGroup.handler(%{action: :ban_member, chat_id: @chat_id}, @agent_ctx)
    end
  end

  describe "schema validation" do
    test "advertises group management actions and execution controls" do
      prism = ManageGroup.view()

      assert prism.input_schema.required == ["action"]
      assert "ban_member" in prism.input_schema.properties.action.enum
      assert "moderate_message" in prism.input_schema.properties.action.enum
      assert "log_admin_action" in prism.input_schema.properties.action.enum
      assert Map.has_key?(prism.input_schema.properties, :execute)
      assert Map.has_key?(prism.output_schema.properties, :requests)
      assert Map.has_key?(prism.output_schema.properties, :audit_entry)
    end
  end
end
