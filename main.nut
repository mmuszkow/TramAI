require("pf_tram.nut");
require("utils.nut");

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
    /* Cache of vehicle group per town. */
    _groups = AIList();
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

        /* MAIN LOOP: Check all the towns with population greater than 1000. */
        local towns = AITownList();
        towns.Valuate(AITown.GetPopulation);
        towns.KeepAboveValue(1000);
        for(local town = towns.Begin(); !towns.IsEnd(); town = towns.Next()) {
            /* Check rating first, if it's so low that we can't build remove all the stops and skip to next. */
            local rating = AITown.GetRating(town, AICompany.COMPANY_SELF);
            if(rating == AITown.TOWN_RATING_APPALLING || rating == AITown.TOWN_RATING_VERY_POOR) {
                RemoveInfrastructure(town);
                continue;
            }

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

        /* Rating boosters. */
        local trees_planted = PlantTreesIfRich();
        if(trees_planted > 0)
            AILog.Info("Planted " + trees_planted + " trees");
        BuildHQ();

        this.Sleep(50);
    }
}

function TramAI::RemoveInfrastructure(town) {
    /* Get vehicles in the town and sell them (if any). */
    local group = GetGroup(town);
    if(AIGroup.IsValidGroup(group)) {
        local vehicles = AIVehicleList_Group(group);
        if(!vehicles.IsEmpty()) {
            /* Send to depot and sell what we can. */
            for(local vehicle = vehicles.Begin(); !vehicles.IsEnd(); vehicle = vehicles.Next())
                if(AIVehicle.IsStoppedInDepot(vehicle))
                    AIVehicle.SellVehicle(vehicle);
                else
                    AIVehicle.SendVehicleToDepot(vehicle);

            /* Check if there are still some vehicles left to sale. */
            vehicles = AIVehicleList_Group(group);
            if(!vehicles.IsEmpty())
                return false;
        } else
            AIGroup.DeleteGroup(group);
    }

    /* Get infrastructure in the town. */
    local stations = AIStationList(AIStation.STATION_BUS_STOP);
    stations.Valuate(AIStation.GetNearestTown);
    stations.KeepValue(town);

    local depots = AIDepotList(AITile.TRANSPORT_ROAD);
    depots.Valuate(AITile.GetTownAuthority);
    depots.KeepValue(town);

    local tracks = GetTownInfluencedArea(town);
    tracks.Valuate(AIRoad.HasRoadType, AIRoad.ROADTYPE_TRAM);
    tracks.KeepValue(1);
    tracks.Valuate(AITile.GetTownAuthority);
    tracks.KeepValue(town);
    /* Unfortunately this gives us the owner of the road, not the track. */
    //tracks.Valuate(AITile.GetOwner);
    //tracks.KeepValue(AICompany.COMPANY_SELF);

    if(stations.IsEmpty() && depots.IsEmpty() == 0 && tracks.IsEmpty() == 0)
        return true;

    //AILog.Info(AITown.GetName(town) + " infrastructure to remove: " + stations.Count() + " stations, " + depots.Count() + " depots, " + tracks.Count() + " tracks");

    /* Remove all of the infrastructure. */
    for(local station = stations.Begin(); !stations.IsEnd(); station = stations.Next()) {
        WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_BUS_STOP));
        if(!AIRoad.RemoveRoadStation(AIStation.GetLocation(station))) {
            local err_str = AIError.GetLastErrorString();
            AILog.Error("Failed to remove station " + AIStation.GetName(station) + ": " + err_str);
            return false;
        }
    }

    for(local depot = depots.Begin(); !depots.IsEnd(); depot = depots.Next()) {
        WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_DEPOT));
        if(!AIRoad.RemoveRoadDepot(depot)) {
            local err_str = AIError.GetLastErrorString();
            AILog.Error("Failed to remove depot in " + AITown.GetName(town) + ": " + err_str);
            return false;
        }
    }

    local track_removal_failed = false;
    for(local track = tracks.Begin(); !tracks.IsEnd(); track = tracks.Next()) {
        foreach(dir in [NORTH, WEST, SOUTH, EAST]) {
            if(AIRoad.HasRoadType(track, AIRoad.ROADTYPE_TRAM)) {
                WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_ROAD));
                if(!AIRoad.RemoveRoad(track, track + dir)) {
                    local err = AIError.GetLastError();
                    /* It sucks, but we have no way of getting the owner of the tracks.
                     * We also have no way of determining the direction of tracks not connected to anything (single tile).
                     * So we brute force it here.
                     */
                    if(err != AIError.ERR_OWNED_BY_ANOTHER_COMPANY && err != AIError.ERR_UNKNOWN) {
                        if(err != AIError.ERR_VEHICLE_IN_THE_WAY) {
                            local err_str = AIError.GetLastErrorString();
                            local x = AIMap.GetTileX(track);
                            local y = AIMap.GetTileY(track);
                            AILog.Error("Failed to remove track at (" + x + "," + y + "): " + err_str);
                        }
                        track_removal_failed = true;
                    }
                }
            }
        }
    }

    return !track_removal_failed;
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

function TramAI::GetGroup(town) {
    if(this._groups.HasItem(town))
        return this._groups.GetValue(town);

    local groups = AIGroupList();
    local group_name = AITown.GetName(town) + " trams";
    for(local group = groups.Begin(); !groups.IsEnd(); group = groups.Next()) {
        if(AIGroup.GetName(group) == group_name) {
            /* This can happen when we load game from save, cache entry is not yet filled. */
            this._groups.AddItem(town, group);
            return group;
        }
    }

    local group = AIGroup.CreateGroup(AIVehicle.VT_ROAD);
    if(!AIGroup.IsValidGroup(group)) {
        AILog.Error("Failed to create a vehicle group: " + AIError.GetLastErrorString());
        return -1;
    }

    if(!AIGroup.SetName(group, group_name)) {
        AILog.Error("Failed to set name for the vehicle group: " + AIError.GetLastErrorString());
        AIGroup.DeleteGroup(group);
        return -1;
    }

    this._groups.AddItem(town, group);
    return group;
}

/* Get existing or build a new vehicle for specific stop. */
function TramAI::GetVehicle(town, depot, stop) {
    local station = AIStation.GetStationID(stop);
    if(!AIStation.IsValidStation(station))
        return -1;
    
    /* Reuse existing vehicle. */
    local vehicles = AIVehicleList_Station(station);
    if(vehicles.Count() > 0)
        return vehicles.Begin();
    
    /* Get the group for all vehicles in this town. */
    local group = GetGroup(town);
    if(!AIGroup.IsValidGroup(group))
        return -1;
       
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

    /* Move to the proper group. */
    if(!AIGroup.MoveVehicle(group, vehicle)) {
        AIVehicle.SellVehicle(vehicle);
        AILog.Error("Failed to add tram to a group: " + AIError.GetLastErrorString());
        return -1;
    }

    AILog.Info("New vehicle added for " + AIStation.GetName(station));

    return vehicle;
}

function TramAI::PrepareVehicles(town, depot, stops) {
    for(local stop = stops.Begin(); !stops.IsEnd(); stop = stops.Next()) {
        local vehicle = GetVehicle(town, depot, stop);
        if(vehicle == -1)
            return false;
    
        /* Append orders:
         * 1. go to depot if maintenance needed
         * 2. go to stop X
         * 3. go to closest stop to stop X
         */
        if(AIOrder.GetOrderCount(vehicle) == 0) {
            AIOrder.UnshareOrders(vehicle);
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
    AIRoad.SetCurrentRoadType(AIRoad.ROADTYPE_TRAM);
    for(local stop = stops.Begin(); !stops.IsEnd(); stop = stops.Next()) {
        if(!AIStation.IsValidStation(AIStation.GetStationID(stop))) {
            local front = stop + SOUTH;
            local back = stop + NORTH;
            if(AIRoad.IsRoadTile(stop + WEST) || AIRoad.IsDriveThroughRoadStationTile(stop + WEST)) {
                front = stop + WEST;
                back = stop + EAST;
            }

            /* Build station. */
            WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_BUS_STOP));
            if(!AIRoad.BuildDriveThroughRoadStation(stop, front, AIRoad.ROADVEHTYPE_BUS, AIStation.STATION_NEW)) {
                local err = AIError.GetLastError();
                local err_str = AIError.GetLastErrorString();
                /* It seems that there is no way to detect all types of junctions. Trying to build a stop on 
                   junction returns ERR_UNKNOWN, such tiles are ommited in the next search.
                   Similar for drive through stations and tracks of other companies. We can detect them but it's easier to ignore them.
                   */
                if(err != AIError.ERR_UNKNOWN && err != AIError.ERR_OWNED_BY_ANOTHER_COMPANY && err != AIRoad.ERR_ROAD_DRIVE_THROUGH_WRONG_DIRECTION) {
                    if(err != AIError.ERR_VEHICLE_IN_THE_WAY) {
                        local err_str = AIError.GetLastErrorString();
                        local x = AIMap.GetTileX(stop);
                        local y = AIMap.GetTileY(stop);
                        AILog.Error("Failed to build station at (" + x + "," + y + "): " + err_str);
                        //AISign.BuildSign(stop, err_str);
                    }
                } else
                    this._ignored.AddTile(stop);
                return false;
            }
            
            /* Build loop. */
            foreach(loop in [front, back]) {
                if(!AIRoad.AreRoadTilesConnected(loop, stop)) {
                    WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_ROAD));
                    if(!AIRoad.BuildRoad(loop, stop)) {
                        local err = AIError.GetLastError();
                        if(err == AIError.ERR_OWNED_BY_ANOTHER_COMPANY) {
                            AIRoad.RemoveRoadStation(stop);
                            this._ignored.AddTile(stop);
                        } else if(err != AIError.ERR_VEHICLE_IN_THE_WAY) {
                            local err_str = AIError.GetLastErrorString();
                            local x = AIMap.GetTileX(loop);
                            local y = AIMap.GetTileY(loop);
                            AILog.Error("Failed to build loop at (" + x + "," + y + "): " + err_str);
                            AIRoad.RemoveRoadStation(stop);
                            //AISign.BuildSign(stop, err_str);
                        }
                        return false;
                    }
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
    foreach(dir in [NORTH, SOUTH, EAST, WEST]) {
        if(AIRoad.IsRoadTile(tile + dir) || AIRoad.IsDriveThroughRoadStationTile(tile + dir)) {
            if(AIRoad.BuildRoadDepot(tile, tile + dir)) {
                AIRoad.BuildRoad(tile + dir, tile);
                AILog.Info("Depot built in " + AITown.GetName(town));
                return tile;
            }
            local err_str = AIError.GetLastErrorString();
            local x = AIMap.GetTileX(tile);
            local y = AIMap.GetTileY(tile);
            AILog.Error("Failed to build depot at (" + x + "," + y + "): " + err_str);
        }
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
        AILog.Error("No path found to build track");
        return false;
    }
    
    local tmp_path = _pf.path;
    while(tmp_path != null) {
        if(tmp_path.prev != null) {
             if(AIBridge.IsBridgeTile(tmp_path.tile)) {
                /* Bridge. */
                local other_end = AIBridge.GetOtherBridgeEnd(tmp_path.tile);
                if(!AIRoad.AreRoadTilesConnected(other_end, tmp_path.prev.tile)) {
                    WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_ROAD));
                    if(!AIRoad.BuildRoad(other_end, tmp_path.prev.tile) && !AIRoad.BuildRoad(tmp_path.prev.tile, other_end)) {
                        local err = AIError.GetLastError();
                        if(err != AIError.ERR_VEHICLE_IN_THE_WAY) {
                            local err_str = AIError.GetLastErrorString();
                            local x = AIMap.GetTileX(other_end);
                            local y = AIMap.GetTileY(other_end);
                            local x2 = AIMap.GetTileX(tmp_path.prev.tile);
                            local y2 = AIMap.GetTileY(tmp_path.prev.tile);
                            AILog.Error("Failed to build track between (" + x + "," + y + ") and (" + x2 + "," + y2 + "): " + err_str);
                            //AISign.BuildSign(tmp_path.tile, err_str);
                        }
                        return false;
                    }
                }
             } else {
                /* Non-bridge. */
                if(!AIRoad.AreRoadTilesConnected(tmp_path.tile, tmp_path.prev.tile)) {
                    WaitToHaveEnoughMoney(AIRoad.GetBuildCost(AIRoad.ROADTYPE_TRAM, AIRoad.BT_ROAD));
                     if(!AIRoad.BuildRoad(tmp_path.tile, tmp_path.prev.tile) && !AIRoad.BuildRoad(tmp_path.prev.tile, tmp_path.tile)) {
                        local err = AIError.GetLastError();
                        if(err != AIError.ERR_VEHICLE_IN_THE_WAY) {
                            local err_str = AIError.GetLastErrorString();
                            local x = AIMap.GetTileX(tmp_path.tile);
                            local y = AIMap.GetTileY(tmp_path.tile);
                            local x2 = AIMap.GetTileX(tmp_path.prev.tile);
                            local y2 = AIMap.GetTileY(tmp_path.prev.tile);
                            AILog.Error("Failed to build track between (" + x + "," + y + ") and (" + x2 + "," + y2 + "): " + err_str);
                            //AISign.BuildSign(tmp_path.tile, err_str);
                        }
                        return false;
                    }
                }
            }
        }        
        tmp_path = tmp_path.prev;
    }
    
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

