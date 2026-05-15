defmodule Lux.Integrations.Telegram.GroupManagerTest do
  use UnitAPICase, async: true

  alias Lux.Integrations.Telegram.GroupManager

  @chat_id -100_123_456
  @user_id 987_654
  @message_id 42

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  describe "permission and admin templates" do
    test "builds Telegram ChatPermissions templates with current permission flags" do
      assert {:ok, permissions} = GroupManager.permission_template(:media_limited)

      assert permissions.can_send_messages == true
      assert permissions.can_send_photos == false
      assert permissions.can_add_web_page_previews == false
      assert Map.has_key?(permissions, :can_react_to_messages)
      assert Map.has_key?(permissions, :can_edit_tag)
    end

    test "builds administrator role templates" do
      assert {:ok, rights} = GroupManager.admin_template("moderator")

      assert rights.can_manage_chat == true
      assert rights.can_delete_messages == true
      assert rights.can_restrict_members == true
      assert rights.can_post_messages == false
    end
  end

  describe "member and permission plans" do
    test "plans member restrictions with named permission templates" do
      assert {:ok, plan} =
               GroupManager.plan(:restrict_member, %{
                 chat_id: @chat_id,
                 user_id: @user_id,
                 permission_template: :read_only,
                 until_date: 1_766_000_000
               })

      assert plan.category == :member_management
      assert plan.request_count == 1

      [request] = plan.requests
      assert request.method == :post
      assert request.path == "/restrictChatMember"
      assert request.payload.chat_id == @chat_id
      assert request.payload.user_id == @user_id
      assert request.payload.until_date == 1_766_000_000
      assert Enum.all?(request.payload.permissions, fn {_key, value} -> value == false end)
    end

    test "plans demotion by clearing all admin rights through promoteChatMember" do
      assert {:ok, plan} =
               GroupManager.plan("demote_member", %{
                 "chat_id" => @chat_id,
                 "user_id" => @user_id
               })

      [request] = plan.requests
      assert request.path == "/promoteChatMember"
      assert request.payload.chat_id == @chat_id
      assert request.payload.user_id == @user_id
      assert request.payload.can_manage_chat == false
      assert request.payload.can_restrict_members == false
      assert request.payload.can_promote_members == false
    end

    test "plans member tags and sender-chat moderation" do
      assert {:ok, tag_plan} =
               GroupManager.plan(:set_member_tag, %{
                 chat_id: @chat_id,
                 user_id: @user_id,
                 tag: "vip"
               })

      assert [%{path: "/setChatMemberTag", payload: %{tag: "vip"}}] = tag_plan.requests

      assert {:ok, sender_plan} =
               GroupManager.plan(:ban_sender_chat, %{
                 chat_id: @chat_id,
                 sender_chat_id: -100_777_777
               })

      assert [%{path: "/banChatSenderChat", payload: %{sender_chat_id: -100_777_777}}] =
               sender_plan.requests
    end

    test "plans default chat permission updates" do
      assert {:ok, plan} =
               GroupManager.plan(:set_permissions, %{
                 chat_id: @chat_id,
                 permissions: %{
                   "can_send_photos" => false,
                   can_send_messages: true,
                   can_add_web_page_previews: false
                 },
                 use_independent_chat_permissions: true
               })

      [request] = plan.requests
      assert request.path == "/setChatPermissions"
      assert request.payload.permissions.can_send_messages == true
      assert request.payload.permissions.can_send_photos == false
      assert request.payload.use_independent_chat_permissions == true
    end
  end

  describe "settings and channel post plans" do
    test "plans group settings and invite link operations" do
      assert {:ok, title_plan} =
               GroupManager.plan(:set_title, %{chat_id: @chat_id, title: "Lux Research"})

      assert [%{path: "/setChatTitle", payload: %{title: "Lux Research"}}] = title_plan.requests

      assert {:ok, invite_plan} =
               GroupManager.plan(:create_invite_link, %{
                 chat_id: @chat_id,
                 name: "moderator-review",
                 member_limit: 5,
                 creates_join_request: true
               })

      [invite_request] = invite_plan.requests
      assert invite_request.path == "/createChatInviteLink"
      assert invite_request.payload.name == "moderator-review"
      assert invite_request.payload.member_limit == 5
      assert invite_request.payload.creates_join_request == true
    end

    test "plans channel post create, edit, delete, forward, and copy actions" do
      for {action, expected_path, params} <- [
            {:send_channel_post, "/sendMessage", %{text: "Launch update"}},
            {:edit_channel_post, "/editMessageText", %{message_id: @message_id, text: "Updated"}},
            {:delete_channel_post, "/deleteMessage", %{message_id: @message_id}},
            {:delete_messages, "/deleteMessages", %{message_ids: [40, 41, 42]}},
            {:forward_channel_post, "/forwardMessage",
             %{from_chat_id: -100_555_555, message_id: @message_id}},
            {:copy_channel_post, "/copyMessage",
             %{from_chat_id: -100_555_555, message_id: @message_id}}
          ] do
        assert {:ok, plan} = GroupManager.plan(action, Map.put(params, :chat_id, @chat_id))
        assert [%{path: ^expected_path}] = plan.requests
      end
    end
  end

  describe "moderation and audit logging" do
    test "builds moderation plans with violations, action requests, and audit log requests" do
      assert {:ok, plan} =
               GroupManager.plan(:moderate_message, %{
                 chat_id: @chat_id,
                 user_id: @user_id,
                 message_id: @message_id,
                 admin_id: 111,
                 text: "FREE money at https://spam.example AAAAAAA",
                 moderation_action: :restrict_member,
                 log_chat_id: -100_999,
                 policy: %{
                   blocked_terms: ["free money"],
                   blocked_patterns: ["spam\\.example"],
                   block_links: true,
                   max_repeated_chars: 4
                 }
               })

      assert plan.status == :flagged
      assert plan.severity == :high
      assert plan.moderation_action == :restrict_member

      assert Enum.map(plan.violations, & &1.type) == [
               :blocked_term,
               :blocked_pattern,
               :link,
               :repeated_characters
             ]

      assert Enum.map(plan.requests, & &1.path) == [
               "/deleteMessage",
               "/restrictChatMember",
               "/sendMessage"
             ]

      assert plan.audit_entry.action == "moderate_message"
      assert plan.audit_entry.status == :flagged
      assert plan.audit_entry.target_user_id == @user_id
    end

    test "returns a clean moderation plan without API requests" do
      assert {:ok, plan} =
               GroupManager.plan(:moderate_message, %{
                 chat_id: @chat_id,
                 text: "Thanks for the update.",
                 policy: %{blocked_terms: ["scam"], block_links: true}
               })

      assert plan.status == :clean
      assert plan.request_count == 0
      assert plan.requests == []
      assert plan.violations == []
    end

    test "plans standalone admin log delivery" do
      assert {:ok, plan} =
               GroupManager.plan(:log_admin_action, %{
                 logged_action: "manual_review",
                 chat_id: @chat_id,
                 admin_id: 111,
                 user_id: @user_id,
                 message_id: @message_id,
                 reason: "Escalated for moderator review",
                 log_chat_id: -100_999
               })

      assert plan.category == :admin_logging
      assert [%{path: "/sendMessage", payload: payload}] = plan.requests
      assert payload.chat_id == -100_999
      assert payload.text =~ "action=manual_review"
      assert payload.text =~ "reason=Escalated for moderator review"
    end
  end

  describe "execution" do
    test "executes planned requests through the Telegram client" do
      Req.Test.expect(TelegramClientMock, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path =~ "/banChatMember"

        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        decoded_body = Jason.decode!(body)
        assert decoded_body["chat_id"] == @chat_id
        assert decoded_body["user_id"] == @user_id
        assert decoded_body["revoke_messages"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => true}))
      end)

      assert {:ok, plan} =
               GroupManager.plan(:ban_member, %{
                 chat_id: @chat_id,
                 user_id: @user_id,
                 revoke_messages: true
               })

      assert {:ok, executed} = GroupManager.execute(plan)
      assert executed.executed == true
      assert [%{response: %{"result" => true}}] = executed.results
    end
  end

  describe "validation" do
    test "rejects invalid required parameters and invalid patterns" do
      assert {:error, "Missing or invalid user_id"} =
               GroupManager.plan(:ban_member, %{chat_id: @chat_id})

      assert {:error, "slow_mode_delay must be between 0 and 36000"} =
               GroupManager.plan(:set_slow_mode, %{chat_id: @chat_id, slow_mode_delay: 36_001})

      assert {:error, "message_ids must contain only integers"} =
               GroupManager.plan(:delete_messages, %{chat_id: @chat_id, message_ids: [1, "2"]})

      assert {:error, message} =
               GroupManager.plan(:moderate_message, %{
                 chat_id: @chat_id,
                 text: "hello",
                 policy: %{blocked_patterns: ["["]}
               })

      assert message =~ "Invalid blocked pattern"
    end
  end
end
