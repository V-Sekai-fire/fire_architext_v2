# Copyright (c) 2023-present. This file is part of V-Sekai https://v-sekai.org/.
# K. S. Ernest (Fire) Lee & Contributors
# insert_rooms.exs
# SPDX-License-Identifier: MIT

defmodule ArchiText.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end

defmodule ArchiText.Room do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "rooms" do
    field(:room_type, :string)
    field(:room_coordinates, Geo.PostGIS.Geometry)
  end
end

defmodule ArchiText.Apartment do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "apartments" do
    field(:apartment_layout, :string)
  end
end

def to_jsonl(apartment_room) do
  apartment = Repo.get!(Apartment, apartment_room.apartment_id)
  rooms = Repo.all(from(r in Room, where: r.apartment_id == ^apartment.id))

  room_descriptions =
    Enum.map(rooms, fn room ->
      coordinates =
        room.room_coordinates
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.chunk_every(2)
        |> Enum.map(fn [x, y] -> "(#{x} #{y})" end)
        |> Enum.join(", ")

      "The room type is #{room.room_type}, and its coordinates are MULTIPOLYGON (((#{coordinates})))."
    end)

  conversation = %{
    from:
      "Imagine an apartment that suits your lifestyle. The apartment layout is #{apartment.apartment_layout}. This output provides a detailed description of an apartment with a #{apartment.apartment_layout} layout along with its rooms. Each room is thoughtfully placed and designed to maximize space and functionality. The spatial relationship between rooms is also indicated, particularly if they are adjacent. In addition, each room's location is defined using the 'Well-known Text' (WKT) markup language for representing vector geometry objects on a map. In this syntax, a MULTIPOLYGON is represented as a ring of points that ends where it started.",
    value:
      "The apartment layout is #{apartment.apartment_layout}.\n#{Enum.join(room_descriptions, "\n")}"
  }

  json = Jason.encode!(%{conversations: [conversation]})

  json_stream =
    Stream.unfold(json, fn
      "" -> nil
      rest -> {String.slice(rest, 0, 1), String.slice(rest, 1..-1)}
    end)

  json_stream
  |> Stream.into(File.stream!("path_to_your_file.jsonl", [:append]))
  |> Stream.run()
end

defmodule ArchiText.RoomService do
  def insert_room(apartment_id, room_type, room_coordinates) do
    overlapping_rooms =
      ArchiText.Repo.all(
        from(r in ArchiText.Room,
          where: fragment("? && ?", r.room_coordinates, ^room_coordinates)
        )
      )

    if overlapping_rooms != [] do
      raise "Room coordinates overlap with an existing room."
    end

    new_room =
      %ArchiText.Room{room_type: room_type, room_coordinates: room_coordinates}
      |> ArchiText.Repo.insert!()

    %ArchiText.ApartmentRoom{apartment_id: apartment_id, room_id: new_room.id}
    |> ArchiText.Repo.insert!()
  end
end

defmodule ArchiText.LayoutParser do
  def parse(layout_string) do
    layout_string
    |> String.split(", ")
    |> Enum.map(&parse_room/1)
  end

  defp parse_room(room_string) do
    [room_type, coordinates_string] = String.split(room_string, ": ")

    coordinates =
      coordinates_string
      |> String.trim("()")
      |> String.split(")(")
      |> Enum.map(&parse_coordinates/1)

    coordinates = coordinates ++ [List.first(coordinates)]

    polygon = %Geo.Polygon{coordinates: [coordinates]}
    multi_polygon = %Geo.MultiPolygon{coordinates: [[polygon]]}

    {room_type, multi_polygon}
  end

  defp parse_coordinates(coordinate_string) do
    [x, y] = String.split(coordinate_string, ",")
    %Geo.Point{coordinates: {String.to_float(x), String.to_float(y)}}
  end

  def parse_prompt(prompt_string) do
    [apartment_layout, layout_string] = String.split(prompt_string, "[Layout]")

    apartment_layout = String.trim(apartment_layout)
    layout_string = String.trim(layout_string)

    {apartment_layout, parse(layout_string)}
  end
end

defmodule ArchiText.LayoutParserTest do
  use ExUnit.Case

  alias ArchiText.LayoutParser

  describe "parse/1" do
    test "parses layout string into room types and coordinates" do
      layout_string =
        "[Layout] bedroom: (209,172)(150,172)(150,143)(209,143), living_room: (135,128)(47,128)(47,40)(135,40)"

      assert LayoutParser.parse(layout_string) == [
               {"bedroom",
                %Geo.MultiPolygon{
                  coordinates: [
                    %Geo.Polygon{
                      coordinates: [
                        [
                          %Geo.Point{coordinates: {209, 172}},
                          %Geo.Point{coordinates: {150, 172}},
                          %Geo.Point{coordinates: {150, 143}},
                          %Geo.Point{coordinates: {209, 143}}
                        ]
                      ]
                    }
                  ]
                }},
               {"living_room",
                %Geo.MultiPolygon{
                  coordinates: [
                    %Geo.Polygon{
                      coordinates: [
                        [
                          %Geo.Point{coordinates: {135, 128}},
                          %Geo.Point{coordinates: {47, 128}},
                          %Geo.Point{coordinates: {47, 40}},
                          %Geo.Point{coordinates: {135, 40}}
                        ]
                      ]
                    }
                  ]
                }}
             ]
    end
  end

  describe "parse_room/1" do
    test "parses room string into room type and coordinates" do
      room_string = "bedroom: (209,172)(150,172)(150,143)(209,143)"

      assert LayoutParser.parse_room(room_string) ==
               {"bedroom",
                %Geo.MultiPolygon{
                  coordinates: [
                    %Geo.Polygon{
                      coordinates: [
                        [
                          %Geo.Point{coordinates: {209, 172}},
                          %Geo.Point{coordinates: {150, 172}},
                          %Geo.Point{coordinates: {150, 143}},
                          %Geo.Point{coordinates: {209, 143}}
                        ]
                      ]
                    }
                  ]
                }}
    end
  end

  describe "parse_coordinates/1" do
    test "parses coordinate string into a Geo.Point struct" do
      coordinate_string = "209,172"

      assert LayoutParser.parse_coordinates(coordinate_string) == %Geo.Point{
               coordinates: {209, 172}
             }
    end
  end

  describe "parse_apartment_name/1" do
    test "parses apartment name from the prompt" do
      prompt = "[User prompt] a house with nine rooms and a corridor"

      assert LayoutParser.parse_apartment_name(prompt) == "a house with nine rooms and a corridor"
    end
  end

  describe "parse_prompt/1" do
    test "parses prompt string into apartment name and room types and coordinates" do
      prompt_string =
        "[User prompt] a bathroom is located in the west side of the house [Layout] bathroom: (201,194)(172,194)(172,165)(187,165)(187,150)(201,150), bedroom: (187,135)(128,135)(128,77)(187,77)"

      assert LayoutParser.parse_prompt(prompt_string) ==
               {"a bathroom is located in the west side of the house",
                [
                  {"bathroom",
                   %Geo.MultiPolygon{
                     coordinates: [
                       %Geo.Polygon{
                         coordinates: [
                           [
                             %Geo.Point{coordinates: {201, 194}},
                             %Geo.Point{coordinates: {172, 194}},
                             %Geo.Point{coordinates: {172, 165}},
                             %Geo.Point{coordinates: {187, 165}},
                             %Geo.Point{coordinates: {187, 150}},
                             %Geo.Point{coordinates: {201, 150}}
                           ]
                         ]
                       }
                     ]
                   }},
                  {"bedroom",
                   %Geo.MultiPolygon{
                     coordinates: [
                       %Geo.Polygon{
                         coordinates: [
                           [
                             %Geo.Point{coordinates: {187, 135}},
                             %Geo.Point{coordinates: {128, 135}},
                             %Geo.Point{coordinates: {128, 77}},
                             %Geo.Point{coordinates: {187, 77}}
                           ]
                         ]
                       }
                     ]
                   }}
                ]}
    end
  end
end
