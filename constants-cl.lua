---@meta

---This is true whenever the current script is executed on the client. ( client and menu states ) See [States](https://wiki.facepunch.com/gmod/States). Always present.
---@type true
CLIENT = true

---This is true whenever the current script is executed on the client state. See [States](https://wiki.facepunch.com/gmod/States).
---@type true
CLIENT_DLL = true

---This is true whenever the current script is executed on the server state. See [States](https://wiki.facepunch.com/gmod/States). Always present.
---@type false
SERVER = false

---This is true whenever the current script is executed on the server state.
---@type false
GAME_DLL = false

---This is true when the script is being executed in the menu state. See [States](https://wiki.facepunch.com/gmod/States).
---@type false
MENU_DLL = false

---Contains the name of the current active gamemode.
---@type string
GAMEMODE_NAME = "sandbox"

---Represents a non existent entity.
---@type Entity
NULL = Entity(0)

---Contains the version number of GMod. Example: `"201211"`
---@type number
VERSION = 201211

---Contains a nicely formatted version of GMod. Example: `"2020.12.11"`
---@type string
VERSIONSTR = "2020.12.11"

---The branch the game is running on. This will be `"unknown"` on main branch. While this variable is always available in the [Client](https://wiki.facepunch.com/gmod/States#client) & [Menu](https://wiki.facepunch.com/gmod/States#menu) realms, it is only defined in the [Server](https://wiki.facepunch.com/gmod/States#server) realm on local servers.
---@type string
BRANCH = "unknown"

-- ---Current Lua version. This contains `"Lua 5.1"` in GMod at the moment.
-- ---@type string
-- _VERSION = "Lua 5.1"

---Contains the current networking version. Example: `"2023.06.28"`
---
---#### 🗒️ NOTE
---
---This only exists in the Menu state
---@type string
NETVERSIONSTR = "2023.06.28"

---Contains the maximum number of bits for [net.WriteEntity](https://wiki.facepunch.com/gmod/net.WriteEntity)
---@type number
MAX_EDICT_BITS = 16

---The active _env\_skypaint_ entity.
---@type Entity
g_SkyPaint = Entity(0)

---Base panel used for context menus.
---@type ContextBase
g_ContextMenu = Panel()

---Base panel for displaying incoming/outgoing voice messages.
---@type DPanel
g_VoicePanelList = DPanel()

---Base panel for the spawn menu.
---@type EditablePanel
g_SpawnMenu = Panel()

---Main menu of Gmod. (only available in the menu state)
---@type EditablePanel
pnlMainMenu = Panel()

---= Vector(0, 0, 0)
---@type Vector
vector_origin = Vector(0, 0, 0)

---= Vector(0, 0, 1)
---@type Vector
vector_up = Vector(0, 0, 1)

---= Angle(0, 0, 0)
---@type Angle
angle_zero = Angle(0, 0, 0)

---= Color(255, 255, 255, 255)
---@type Color
color_white = Color(255, 255, 255, 255)

--- = Color(0, 0, 0, 255)
---@type Color
color_black = Color(0, 0, 0, 255)

--- = Color(255, 255, 255, 0)
---@type Color
color_transparent = Color(255, 255, 255, 0)

---@class Angle
---@field x number The pitch component of the angle.
---@field y number The yaw component of the angle.
---@field z number The roll  component of the angle.
---@field [1] number The pitch component of the angle.
---@field [2] number The yaw component of the angle.
---@field [3] number The roll  component of the angle.
---@field p number The pitch component of the angle.
-- ---@field y number The yaw component of the angle.
---@field r number The roll  component of the angle.
---@field pitch number The pitch component of the angle.
---@field yaw   number The yaw component of the angle.
---@field roll  number The roll  component of the angle.
---@operator add(Angle): Angle # Returns new [Angle](https://wiki.facepunch.com/gmod/Angle) with the result of addition.
---@operator div(number): Angle # Returns new [Angle](https://wiki.facepunch.com/gmod/Angle) with the result of division.
---@operator mul(number): Angle # Returns new [Angle](https://wiki.facepunch.com/gmod/Angle) with the result of multiplication.
---@operator sub(Angle): Angle # Returns new [Angle](https://wiki.facepunch.com/gmod/Angle) with the result of subtraction.
---@operator unm: Angle # Returns new [Angle](https://wiki.facepunch.com/gmod/Angle) with the result of negation.

---@class Color
---@field r number The red component of the color.
---@field g number The green component of the color.
---@field b number The blue component of the color.
---@field a number The alpha component of the color.

---@class Vector
---@field x number The X component of the vector.
---@field y number The Y component of the vector.
---@field z number The Z component of the vector.
---@field [1] number The X component of the vector.
---@field [2] number The Y component of the vector.
---@field [3] number The Z component of the vector.
---@operator add(Vector): Vector # Returns new [Vector](https://wiki.facepunch.com/gmod/Vector) with the result of addition.
---@operator div(number): Vector # Returns new [Vector](https://wiki.facepunch.com/gmod/Vector) with the result of division.
---@operator mul(number | Vector): Vector # Returns new [Vector](https://wiki.facepunch.com/gmod/Vector) with the result of multiplication.
---@operator sub(Vector): Vector # Returns new [Vector](https://wiki.facepunch.com/gmod/Vector) with the result of subtraction.
---@operator unm: Vector # Returns new [Vector](https://wiki.facepunch.com/gmod/Vector) with the result of negation.

---@class VMatrix
---@operator add(VMatrix): VMatrix # Returns new [VMatrix](https://wiki.facepunch.com/gmod/VMatrix) with the result of addition.
---@operator mul(VMatrix | Vector): VMatrix # Returns new [VMatrix](https://wiki.facepunch.com/gmod/VMatrix) or [Vector](https://wiki.facepunch.com/gmod/Vector) with the result of multiplication.
---@operator sub(VMatrix): VMatrix # Returns new [VMatrix](https://wiki.facepunch.com/gmod/VMatrix) with the result of subtraction.
