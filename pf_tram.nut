require("aystar.nut");

class TramPathfinder {
    _aystar = null;
    _reuse_cost = 1;
    _build_cost = 5;
    path = null;

    constructor() {
        _aystar = AyStar(this, this._Cost, this._Estimate, this._Neighbours);
    }
};

function TramPathfinder::FindPath(start, end) {
    this.path = [];
    if(!AIMap.IsValidTile(start) || !AIMap.IsValidTile(end) || start == end)
        return false;
    
    this._aystar.InitializePath([start, this._GetDominantDirection(start, end)], end, AITileList());
    this.path = this._aystar.FindPath(10000);
    if(this.path == false || this.path == null)
        return false;
        
    return true;
}

function TramPathfinder::_Cost(self, path, new_tile, new_direction) {
    if(path == null)
        return 0;

    if(AIRoad.HasRoadType(new_tile, AIRoad.ROADTYPE_TRAM))
        return path.cost + self._reuse_cost;

    return path.cost + self._build_cost;
}

function TramPathfinder::_Estimate(self, cur_tile, cur_direction) {
    /* Result of this function can be multiplied by value greater than 1 to 
     * get results faster, but they won't be optimal */
    return AIMap.DistanceManhattan(cur_tile, self._aystar._goal) * self._reuse_cost;
}

function TramPathfinder::_GetDominantDirection(from, to) {
    local xDistance = AIMap.GetTileX(from) - AIMap.GetTileX(to);
    local yDistance = AIMap.GetTileY(from) - AIMap.GetTileY(to);
    if (abs(xDistance) >= abs(yDistance)) {
        if (xDistance < 0) return 2;                    // Left
        if (xDistance > 0) return 1;                    // Right
    } else {
        if (yDistance < 0) return 8;                    // Down
        if (yDistance > 0) return 4;                    // Up
    }
}

function TramPathfinder::_GetDirection(from, to) {
    if (from - to >= AIMap.GetMapSizeX()) return 4;     // Up
    if (from - to > 0) return 1;                        // Right
    if (from - to <= -AIMap.GetMapSizeX()) return 8;    // Down
    if (from - to < 0) return 2;                        // Left
}

function TramPathfinder::_Neighbours(self, path, cur_node) {
    local tiles = [];
    local offsets = [
        NORTH,
        SOUTH,
        WEST,
        EAST
    ];

    foreach(offset in offsets) {
        local next = cur_node + offset;
        /* Do not go back. */
        if(next == path.tile)
            continue;
        
        if(next == self._aystar._goal) {
            tiles.append([next, self._GetDirection(cur_node, next)]);
            continue;
        }
        
        if(AIBridge.IsBridgeTile(next)) {
            next = AIBridge.GetOtherBridgeEnd(next);
            if(next != cur_node)
                tiles.append([next, self._GetDirection(cur_node, next)]);
        } else if(AIRoad.IsRoadTile(next))
            tiles.append([next, self._GetDirection(cur_node, next)]);                             
    }
    return tiles;
}
