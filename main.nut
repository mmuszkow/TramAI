require("pf_tram.nut");

class TramAI extends AIController {
    constructor() {}
    
    /* Passengers cargo id. */
    _passenger_cargo_id = -1;
    /* Tram station coverage. */
    _station_radius = 4;
    /* A* pathfinder. */
    _pf = TramPathfinder();
    /* List of tiles that won't be considered during search. */
    _ignored = AITileList();
}

NORTH <- AIMap.GetTileIndex(0, -1);
SOUTH <- AIMap.GetTileIndex(0, 1);
WEST <- AIMap.GetTileIndex(1, 0);
EAST <- AIMap.GetTileIndex(-1, 0);

function TramAI::Save() { return {}; }

function TramAI::Start() {
    AICompany.SetLoanAmount(0);
    SetCompanyName();
    AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_TRAM);
    
    this._passenger_cargo_id = GetPassengersCargoID();
    this._station_radius = AIStation.GetCoverageRadius(AIStation.STATION_BUS_STOP);
    
    /* Sleep if trams not available. */
    if(!AreTramsAllowed())
        AILog.Warning("Not possible to build trams - falling asleep");
    while(!AreTramsAllowed()) { this.Sleep(1000); }   
    
    while(true) {
        /* Sell old trams which are stopped in depot. New ones will be bought in the loop below. */
        local vehicles = AIVehicleList();
        for(local veh = vehicles.Begin(); !vehicles.IsEnd(); veh = vehicles.Next())
            if(AIVehicle.GetAge(veh) >= AIVehicle.GetMaxAge(veh)) {
                if(AIVehicle.IsStoppedInDepot(veh))
                    AIVehicle.SellVehicle(veh);
                else
                    AIVehicle.SendVehicleToDepot(veh);
            }
        
        local towns = AITownList();
        towns.Valuate(AITown.GetPopulation);
        towns.KeepAboveValue(1000);
        for(local town = towns.Begin(); !towns.IsEnd(); town = towns.Next()) {
            local stops = FindTramStops(town);
            if(stops.Count() <= 1)
                continue;
                
            if(!BuildTramStops(stops)) {
                AILog.Error("Failed to build tram stops in " + AITown.GetName(town));
                continue;
            }
                
            local depot = GetDepot(town);
            if(depot == -1) {
                AILog.Error("Failed to get depot in " + AITown.GetName(town));
                continue;
            }
                
            if(!BuildTracks(stops, depot)) {
                AILog.Error("Failed to build tram tracks in " + AITown.GetName(town));
                continue;
            }
            
            if(!PrepareVehicles(town, depot, stops)) {
                AILog.Error("Failed to get vehicle in " + AITown.GetName(town));
                continue;
            }
        }
        
        /* Repay the loan if possible. AICompany.GetQuarterlyExpenses returns negative value. */
        if(AICompany.GetLoanAmount() > 0) {
            local money_to_spare = AICompany.GetBankBalance(AICompany.COMPANY_SELF) - 2 * AICompany.GetLoanInterval() + 
                                   AICompany.GetQuarterlyExpenses(AICompany.COMPANY_SELF, AICompany.CURRENT_QUARTER);
            if(money_to_spare > AICompany.GetLoanInterval()) {
                local can_repay = floor(money_to_spare / AICompany.GetLoanInterval().tofloat()).tointeger() * AICompany.GetLoanInterval();
                if(!AICompany.SetLoanAmount(AICompany.GetLoanAmount() - min(can_repay, AICompany.GetLoanAmount())))
                    AILog.Error("Failed to repay the loan: " + AIError.GetLastErrorString());
            }
        }
        
        this.Sleep(50);
    }
}

function __val__CanHaveTramStop(tile, town) {
    return AIRoad.IsRoadTile(tile) &&
           AITile.GetTownAuthority(tile) == town &&
           AITile.GetSlope(tile) == AITile.SLOPE_FLAT &&
           AIRoad.GetNeighbourRoadCount(tile) < 3 &&
          !AIRoad.IsDriveThroughRoadStationTile(tile) &&
          ((AITile.HasTransportType(tile + NORTH, AITile.TRANSPORT_ROAD) && 
            AITile.HasTransportType(tile + SOUTH, AITile.TRANSPORT_ROAD) && 
            AITile.GetSlope(tile + NORTH) == AITile.SLOPE_FLAT &&
            AITile.GetSlope(tile + SOUTH) == AITile.SLOPE_FLAT &&
            !AIBridge.IsBridgeTile(tile + NORTH) && !AIBridge.IsBridgeTile(tile + SOUTH) &&
           !AITile.HasTransportType(tile + EAST, AITile.TRANSPORT_ROAD) &&
           !AITile.HasTransportType(tile + WEST, AITile.TRANSPORT_ROAD)) ||
          (!AITile.HasTransportType(tile + NORTH, AITile.TRANSPORT_ROAD) && 
           !AITile.HasTransportType(tile + SOUTH, AITile.TRANSPORT_ROAD) && 
            AITile.GetSlope(tile + EAST) == AITile.SLOPE_FLAT &&
            AITile.GetSlope(tile + WEST) == AITile.SLOPE_FLAT &&
           !AIBridge.IsBridgeTile(tile + EAST) && !AIBridge.IsBridgeTile(tile + WEST) &&
            AITile.HasTransportType(tile + EAST, AITile.TRANSPORT_ROAD) &&
            AITile.HasTransportType(tile + WEST, AITile.TRANSPORT_ROAD)));
}

function __val__CanHaveDepot(tile) {
    return AITile.IsBuildable(tile) && 
           AITile.GetSlope(tile) == AITile.SLOPE_FLAT && 
        ((AIRoad.IsRoadTile(tile + NORTH) && AITile.GetSlope(tile + NORTH) == AITile.SLOPE_FLAT && !AIRoad.IsDriveThroughRoadStationTile(tile + NORTH)) ||
         (AIRoad.IsRoadTile(tile + SOUTH) && AITile.GetSlope(tile + SOUTH) == AITile.SLOPE_FLAT && !AIRoad.IsDriveThroughRoadStationTile(tile + SOUTH)) ||
         (AIRoad.IsRoadTile(tile + EAST) && AITile.GetSlope(tile + EAST) == AITile.SLOPE_FLAT && !AIRoad.IsDriveThroughRoadStationTile(tile + EAST)) ||
         (AIRoad.IsRoadTile(tile + WEST) && AITile.GetSlope(tile + WEST) == AITile.SLOPE_FLAT && !AIRoad.IsDriveThroughRoadStationTile(tile + WEST)));
}

function TramAI::WaitToHaveEnoughMoney(cost) {
    /* Have some margin, AICompany.GetQuarterlyExpenses returns negative value . */
    local needed = cost + 2 * AICompany.GetLoanInterval() - AICompany.GetQuarterlyExpenses(AICompany.COMPANY_SELF, AICompany.CURRENT_QUARTER);
    if(AICompany.GetBankBalance(AICompany.COMPANY_SELF) < needed && AICompany.GetLoanAmount() != AICompany.GetMaxLoanAmount()) {
        local to_loan = ceil((needed - AICompany.GetBankBalance(AICompany.COMPANY_SELF)) / AICompany.GetLoanInterval().tofloat()).tointeger() * AICompany.GetLoanInterval();
        if(!AICompany.SetLoanAmount(min(AICompany.GetLoanAmount() + to_loan, AICompany.GetMaxLoanAmount())))
            AILog.Error("Failed to take a loan: " + AIError.GetLastErrorString());
    }

    while(cost + 2 * AICompany.GetLoanInterval() -
          AICompany.GetQuarterlyExpenses(AICompany.COMPANY_SELF, AICompany.CURRENT_QUARTER) >
          AICompany.GetBankBalance(AICompany.COMPANY_SELF)) {}
}

/* AITileList.AddRectangle with map size constraints. */
function SafeAddRectangle(list, tile, range) {
    local tile_x = AIMap.GetTileX(tile);
    local tile_y = AIMap.GetTileY(tile);
    local x1 = max(1, tile_x - range);
    local y1 = max(1, tile_y - range);
    local x2 = min(AIMap.GetMapSizeX() - 2, tile_x + range);
    local y2 = min(AIMap.GetMapSizeY() - 2, tile_y + range);
    list.AddRectangle(AIMap.GetTileIndex(x1, y1), AIMap.GetTileIndex(x2, y2)); 
}

function TramAI::IsDenselyPopulated(town, grid_center) {
    local tiles = AITileList();
    SafeAddRectangle(tiles, grid_center, this._station_radius);
    tiles.Valuate(AITile.GetTownAuthority);
    tiles.KeepValue(town);
    tiles.Valuate(AITile.IsWaterTile);
    tiles.RemoveValue(1);
    tiles.Valuate(AITile.GetOwner);
    tiles.KeepValue(AICompany.COMPANY_INVALID);
    tiles.Valuate(AITile.IsBuildable);
    tiles.RemoveValue(1);
    return tiles.Count() / (4 * this._station_radius * this._station_radius) > 0.9;
}

/* Get existing or build a new vehicle. */
function GetVehicle(depot, stop) {          
    local station = AIStation.GetStationID(stop);
    if(!AIStation.IsValidStation(station))
        return -1;
    
    /* Reuse existing vehicle. */
    local vehicles = AIVehicleList_Station(station);
    if(vehicles.Count() > 0)
        return vehicles.Begin();
        
    /* Build new vehicle. */
    local engine = GetBestTram();
    if(!AIEngine.IsValidEngine(engine))
        return -1;
            
    local vehicle_price = AIEngine.GetPrice(engine);
    if(vehicle_price > 0)
        WaitToHaveEnoughMoney(vehicle_price);
            
    local vehicle = AIVehicle.BuildVehicle(depot, engine);
    if(!AIVehicle.IsValidVehicle(vehicle)) {
        local err_str = AIError.GetLastErrorString();
        AILog.Error("Failed to build " + AIEngine.GetName(engine) + ": " + err_str);
        return -1;
    }
    return vehicle;
}

function PrepareVehicles(town, depot, stops) {
    for(local stop = stops.Begin(); !stops.IsEnd(); stop = stops.Next()) {
        local vehicle = GetVehicle(depot, stop);
        if(vehicle == -1)
            return false;
    
        /* Append orders. */
        if(AIOrder.GetOrderCount(vehicle) == 0) {
            AIOrder.UnshareOrders (vehicle);                
            local closest = AITileList();
            closest.AddList(stops);
            closest.RemoveTile(stop);
            closest.Valuate(AIMap.DistanceManhattan, stop);
            closest.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
            AIOrder.AppendOrder(vehicle, depot, AIOrder.OF_SERVICE_IF_NEEDED);
            AIOrder.AppendOrder(vehicle, stop, AIOrder.OF_NONE);
            AIOrder.AppendOrder(vehicle, closest.Begin(), AIOrder.OF_NONE);
            if(AIVehicle.GetState(vehicle) == AIVehicle.VS_STOPPED || AIVehicle.GetState(vehicle) == AIVehicle.VS_IN_DEPOT)
                AIVehicle.StartStopVehicle(vehicle);
        }
    }

    return true;
}

function TramAI::FindTramStopLocation(town, center) {
    /* Find if there is an existing tram stop already. */
    local tiles = AITileList();
    SafeAddRectangle(tiles, center, this._station_radius);
    tiles.Valuate(AIRoad.IsDriveThroughRoadStationTile);
    tiles.KeepValue(1);
    for(local tile = tiles.Begin(); !tiles.IsEnd(); tile = tiles.Next())
        if(AIStation.IsValidStation(AIStation.GetStationID(tile)))
            return tile;

    /* No station, find possible location for one no further than 2 tiles from center. */
    tiles = AITileList();
    SafeAddRectangle(tiles, center, 2); 
    tiles.Valuate(__val__CanHaveTramStop, town);
    tiles.KeepValue(1);
    tiles.RemoveList(this._ignored);
    if(tiles.Count() == 0)
        return -1;
    tiles.Valuate(AIMap.DistanceManhattan, center);
    tiles.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);                
    return tiles.Begin();                   
}

function TramAI::_FindTramStops(visited, stops, town, center) {
    if(AIMap.IsValidTile(center) && !visited.HasItem(center)) {
        visited.AddTile(center);
        local stop = -1;
        if(IsDenselyPopulated(town, center))
            stop = FindTramStopLocation(town, center);        
        if(stop != -1) {
            stops.AddTile(stop);        
            _FindTramStops(visited, stops, town, center + AIMap.GetTileIndex(0, -3 * this._station_radius));
            _FindTramStops(visited, stops, town, center + AIMap.GetTileIndex(0,  3 * this._station_radius));
            _FindTramStops(visited, stops, town, center + AIMap.GetTileIndex(-3 * this._station_radius, 0));
            _FindTramStops(visited, stops, town, center + AIMap.GetTileIndex( 3 * this._station_radius, 0));
        }
    }
}

function TramAI::FindTramStops(town) {
    local stops = AITileList();
    _FindTramStops(AITileList(), stops, town, AITown.GetLocation(town));
    return stops;
}

function TramAI::BuildTramStops(stops) {
    for(local stop = stops.Begin(); !stops.IsEnd(); stop = stops.Next()) {
        if(!AIStation.IsValidStation(AIStation.GetStationID(stop))) {
            local front = stop + SOUTH;
            local back = stop + NORTH;
            if(AIRoad.IsRoadTile(stop + WEST)) {
                front = stop + WEST;
                back = stop + EAST;
            }

            /* Build station. */
            WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_BUS_STOP));
            if(!AIRoad.BuildDriveThroughRoadStation(stop, front, AIRoad.ROADVEHTYPE_BUS, AIStation.STATION_NEW)) {
                local err = AIError.GetLastError();
                /* It seems that there is no way to detect all types of junctions. Trying to build a stop on 
                   junction returns ERR_UNKNOWN, such tiles are ommited in the next search. */
                if(err != AIError.ERR_UNKNOWN) {                    
                    local err_str = AIError.GetLastErrorString();
                    local x = AIMap.GetTileX(stop);
                    local y = AIMap.GetTileY(stop);
                    AILog.Error("Failed to build station at (" + x + "," + y + "): " + err_str);
                } else
                    this._ignored.AddTile(stop);
                //AISign.BuildSign(stop, err_str);
                return false;
            }
            
            /* Build loop. */
            if(!AIRoad.AreRoadTilesConnected(front, stop)) {
                WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_ROAD));
                if(!AIRoad.BuildRoad(front, stop)) {
                    local err_str = AIError.GetLastErrorString();
                    local x = AIMap.GetTileX(front);
                    local y = AIMap.GetTileY(front);
                    AILog.Error("Failed to tracks at (" + x + "," + y + "): " + err_str);
                    AIRoad.RemoveRoadStation(stop);
                    //AISign.BuildSign(front, err_str);
                    return false;
                }
            }
            if(!AIRoad.AreRoadTilesConnected(back, stop)) {
                WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_ROAD));
                if(!AIRoad.BuildRoad(back, stop)) {
                    local err_str = AIError.GetLastErrorString();
                    local x = AIMap.GetTileX(back);
                    local y = AIMap.GetTileY(back);
                    AILog.Error("Failed to tracks at (" + x + "," + y + "): " + err_str);
                    AIRoad.RemoveRoadStation(stop);                    
                    //AISign.BuildSign(back, err_str);
                    return false;
                }
            }
        }
    }
    
    return true;
}

function TramAI::GetDepot(town) {
    /* Return existing. */
    local town_loc = AITown.GetLocation(town);
    local depots = AIDepotList(AITile.TRANSPORT_ROAD);
    depots.Valuate(AITile.GetTownAuthority);
    depots.KeepValue(town);
    depots.Valuate(AIMap.DistanceManhattan, town_loc);
    depots.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);  
    if(depots.Count() > 0)
        return depots.Begin();
        
    /* Find a place for new one. */
    local tiles = AITileList();
    SafeAddRectangle(tiles, town_loc, 40);
    tiles.Valuate(AITile.GetTownAuthority);
    tiles.KeepValue(town);
    tiles.Valuate(__val__CanHaveDepot);
    tiles.KeepValue(1);
    tiles.Valuate(AIMap.DistanceManhattan, town_loc);
    tiles.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
    if(tiles.Count() == 0)
        return -1;
        
    /* Build the depot and connect it to the road. */
    local tile = tiles.Begin();
    WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_DEPOT));
    if(AIRoad.IsRoadTile(tile + NORTH)) {
        if(AIRoad.BuildRoadDepot(tile, tile + NORTH)) {
            AIRoad.BuildRoad(tile + NORTH, tile);
            return tile;
        } 
        local err_str = AIError.GetLastErrorString();
        local x = AIMap.GetTileX(tile);
        local y = AIMap.GetTileY(tile);
        AILog.Error("Failed to build depot at (" + x + "," + y + "): " + err_str);
    } else if(AIRoad.IsRoadTile(tile + SOUTH)) {
        if(AIRoad.BuildRoadDepot(tile, tile + SOUTH)) {
            AIRoad.BuildRoad(tile + SOUTH, tile);
            return tile;
        } 
        local err_str = AIError.GetLastErrorString();
        local x = AIMap.GetTileX(tile);
        local y = AIMap.GetTileY(tile);
        AILog.Error("Failed to build depot at (" + x + "," + y + "): " + err_str);
    } else if(AIRoad.IsRoadTile(tile + EAST)) {
        if(AIRoad.BuildRoadDepot(tile, tile + EAST)) {
            AIRoad.BuildRoad(tile + EAST, tile);
            return tile;
        } 
        local err_str = AIError.GetLastErrorString();
        local x = AIMap.GetTileX(tile);
        local y = AIMap.GetTileY(tile);
        AILog.Error("Failed to build depot at (" + x + "," + y + "): " + err_str);
    } else {
        if(AIRoad.BuildRoadDepot(tile, tile + WEST)) {
            AIRoad.BuildRoad(tile + WEST, tile);
            return tile;
        } 
        local err_str = AIError.GetLastErrorString();
        local x = AIMap.GetTileX(tile);
        local y = AIMap.GetTileY(tile);
        AILog.Error("Failed to build depot at (" + x + "," + y + "): " + err_str);
    }
    
    return -1;
}

function TramAI::AreConnected(src, dst) {
    if(!_pf.FindPath(src, dst))
        return false;
        
    local tmp_path = _pf.path;    
    while(tmp_path != null) {
        if(tmp_path.prev != null) {
            if(AIBridge.IsBridgeTile(tmp_path.tile)) {
                local other_end = AIBridge.GetOtherBridgeEnd(tmp_path.tile);
                if(!AIRoad.AreRoadTilesConnected(other_end, tmp_path.prev.tile))
                    return false;
            } else if(!AIRoad.AreRoadTilesConnected(tmp_path.tile, tmp_path.prev.tile))
                return false;
        }
        tmp_path = tmp_path.prev;
    }
    
    return true;
}

function TramAI::BuildTrack(src, dst) {
    if(!_pf.FindPath(src, dst)) {
        AILog.Error("Weird, no path...");
        return false;
    }
    
    local tmp_path = _pf.path;
    //AISign.BuildSign(src, "src");
    while(tmp_path != null) {
        if(tmp_path.prev != null) {
        
             if(AIBridge.IsBridgeTile(tmp_path.tile)) {
                /* Bridge. */
                local other_end = AIBridge.GetOtherBridgeEnd(tmp_path.tile);
                if(!AIRoad.AreRoadTilesConnected(other_end, tmp_path.prev.tile)) {
                    WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_ROAD));
                    if(!AIRoad.BuildRoad(other_end, tmp_path.prev.tile) && !AIRoad.BuildRoad(tmp_path.prev.tile, other_end)) {
                        local err_str = AIError.GetLastErrorString();
                        local x = AIMap.GetTileX(other_end);
                        local y = AIMap.GetTileY(other_end);
                        local x2 = AIMap.GetTileX(tmp_path.prev.tile);
                        local y2 = AIMap.GetTileY(tmp_path.prev.tile);
                        AILog.Error("Failed to build track between (" + x + "," + y + ") and (" + x2 + "," + y2 + "): " + err_str);
                        //AISign.BuildSign(tmp_path.tile, "x");
                        return false;
                    }
                }
             } else {
                /* Non-bridge. */
                if(!AIRoad.AreRoadTilesConnected(tmp_path.tile, tmp_path.prev.tile)) {
                    WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_ROAD));
                     if(!AIRoad.BuildRoad(tmp_path.tile, tmp_path.prev.tile) && !AIRoad.BuildRoad(tmp_path.prev.tile, tmp_path.tile)) {
                        local err_str = AIError.GetLastErrorString();
                        local x = AIMap.GetTileX(tmp_path.tile);
                        local y = AIMap.GetTileY(tmp_path.tile);
                        local x2 = AIMap.GetTileX(tmp_path.prev.tile);
                        local y2 = AIMap.GetTileY(tmp_path.prev.tile);
                        AILog.Error("Failed to build track between (" + x + "," + y + ") and (" + x2 + "," + y2 + "): " + err_str);
                        //AISign.BuildSign(tmp_path.tile, "x");
                        return false;
                    }
                }
            }
             
            //AISign.BuildSign(tmp_path.tile, "t");
            //AISign.BuildSign(tmp_path.prev.tile, "p");
        }        
        tmp_path = tmp_path.prev;
    }
    
    //AISign.BuildSign(src, "dst");

    return true;
}

function TramAI::BuildTracks(stops, depot) {
    /* Connect depot to the closest station. */
    local depot_front = AIRoad.GetRoadDepotFrontTile(depot);
    if(!AIMap.IsValidTile(depot_front)) {
        AILog.Error("Incorrect depot front tile");
        return false;
    }
    
    if(!AIRoad.AreRoadTilesConnected(depot, depot_front) && !AIRoad.BuildRoad(depot, depot_front)) {
        AILog.Error("Failed to connect depot to tracks");
        return false;
    }
        
    local closest = AITileList();
    closest.AddList(stops);
    closest.Valuate(AIMap.DistanceManhattan, depot_front);
    closest.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
    if(!BuildTrack(closest.Begin(), depot_front))
        return false;
        
    /* Connect each stop to the closest one. */
    for(local stop = stops.Begin(); !stops.IsEnd(); stop = stops.Next()) {
        closest = AITileList();
        closest.AddList(stops);
        closest.RemoveTile(stop);
        closest.Valuate(AIMap.DistanceManhattan, stop);
        closest.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
        if(!BuildTrack(stop, closest.Begin()))
            return false;
            
        if(!AreConnected(stop, depot_front) && !BuildTrack(stop, depot_front))
            return false;
    }
    
    return true;
}

function TramAI::AreTramsAllowed() {
    /* Road vehicles disabled. */
    if(AIGameSettings.IsDisabledVehicleType(AIVehicle.VT_ROAD))
        return false;
    
    /* Tram infrastructure not available. */
    if(!AIRoad.IsRoadTypeAvailable(AIRoad.ROADTYPE_TRAM))
        return false;
    
    /* Max 0 road vehicles. */
    local veh_allowed = AIGameSettings.GetValue("vehicle.max_roadveh");
    if(veh_allowed == 0)
        return false;
    
    /* Current vehicles < ships limit. */
    local veh_list = AIVehicleList();
    veh_list.Valuate(AIVehicle.GetVehicleType);
    veh_list.KeepValue(AIVehicle.VT_ROAD);
    if(veh_list.Count() >= veh_allowed)
        return false;
    
    /* No trams available. */
    if(GetTramModels().Count() == 0)
        return false;
    
    return true;
}

/* Get available tram models list. */
function TramAI::GetTramModels() {
    local engine_list = AIEngineList(AIVehicle.VT_ROAD);
    engine_list.Valuate(AIEngine.GetCargoType);
    engine_list.KeepValue(this._passenger_cargo_id);
    engine_list.Valuate(AIEngine.CanRunOnRoad, AIRoad.ROADTYPE_TRAM);
    engine_list.KeepValue(1);
    return engine_list;
}

function TramAI::GetBestTram() {
    local engines = GetTramModels();
    if(engines.IsEmpty())
        return -1;
    
    /* Get the fastest model. */
    engines.Valuate(AIEngine.GetMaxSpeed);
    engines.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);
    local fastest = engines.Begin();
    
    /* If there are more than 1 model with such speed, choose the one with bigger capacity. */
    engines = GetTramModels();
    engines.Valuate(AIEngine.GetMaxSpeed);
    engines.KeepValue(AIEngine.GetMaxSpeed(fastest));
    if(engines.IsEmpty())
        return -1;
    engines.Valuate(AIEngine.GetCapacity);
    engines.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);
    return engines.Begin();
}

function TramAI::SetCompanyName() {
    if(!AICompany.SetName("TramAI")) {
        local i = 2;
        while(!AICompany.SetName("TramAI #" + i)) {
            i = i + 1;
            if(i > 255) break;
        }
    }
}

/* Gets passengers cargo ID. */
function GetPassengersCargoID() {
    local cargo_list = AICargoList();
    cargo_list.Valuate(AICargo.HasCargoClass, AICargo.CC_PASSENGERS);
    cargo_list.KeepValue(1);
    cargo_list.Valuate(AICargo.GetTownEffect);
    cargo_list.KeepValue(AICargo.TE_PASSENGERS);
    return cargo_list.Begin();
}
