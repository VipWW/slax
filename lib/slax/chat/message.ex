defmodule Slax.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias Slax.Accounts.User
  alias Slax.Chat.{Reaction, Reply, Room}

  schema "messages" do
    field :body, :string

    # By default assumes at the end: , foreign_key: :user_id
    belongs_to :user, User, type: :binary_id
    # By default assumes at the end: , foreign_key: :room_id
    belongs_to :room, Room, type: :binary_id

    has_many :reactions, Reaction
    has_many :replies, Reply

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body])
    |> validate_required([:body])
  end
end
