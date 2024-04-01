/* Ensures that we have enough money to buy something, if not takes a loan. */
function WaitToHaveEnoughMoney(cost) {
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

/* Check if we have enough money to spend it on low priorities tasks like planting trees. */
function WeAreRich() {
    return AICompany.GetBankBalance(AICompany.COMPANY_SELF) -
           AICompany.GetQuarterlyExpenses(AICompany.COMPANY_SELF, AICompany.CURRENT_QUARTER) >
           10 * AICompany.GetMaxLoanAmount();
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

/* All tiles that are within specific town influence. */
function GetTownInfluencedArea(town) {
    local center = AITown.GetLocation(town);

    /* Determine borders. */
    local area_w = 5;
    while( AITile.IsWithinTownInfluence(center + area_w, town)
        || AITile.IsWithinTownInfluence(center - area_w, town))
        area_w += 5;
    local area_h = 5;
    while( AITile.IsWithinTownInfluence(center + area_h, town)
        || AITile.IsWithinTownInfluence(center - area_h, town))
        area_h += 5;

    /* Return tiles list. */
    local area = AITileList();
    SafeAddRectangle(area, center, max(area_w, area_h));
    area.Valuate(AITile.GetTownAuthority);
    area.KeepValue(town);
    return area;
}

/* Plants trees in towns with presence if nothing better to do. This boost company rating in town. */
function PlantTreesIfRich() {
    local planted = 0;
    if(!WeAreRich())
        return planted;

    local towns = AITownList();
    towns.Valuate(AITown.GetRating, AICompany.COMPANY_SELF);
    towns.KeepBelowValue(AITown.TOWN_RATING_GOOD);
    towns.RemoveValue(AITown.TOWN_RATING_NONE);
    towns.RemoveValue(AITown.TOWN_RATING_INVALID);
    towns.Valuate(AITown.GetPopulation);
    towns.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);

    local start = AIDate.GetCurrentDate();

    for(local town_id = towns.Begin(); !towns.IsEnd(); town_id = towns.Next()) {
        /* We plant trees for 1 month max */
        if(AIDate.GetCurrentDate() - start > 30)
            return planted;

        local area = GetTownInfluencedArea(town_id);
        area.Valuate(AITile.IsBuildable);
        area.KeepValue(1);
        area.Valuate(AIBase.RandItem);
        area.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);
        for(local tile = area.Begin(); !area.IsEnd(); tile = area.Next()) {
            if(AITile.PlantTree(tile))
                planted++;
        }
    }

    return planted;
}

/* To check if tile can have HQ built on, HQ is 2x2. */
function _val_CanHaveHQ(tile) {
    return AITile.IsBuildable(tile) &&
           AITile.IsBuildable(tile + SOUTH) &&
           AITile.IsBuildable(tile + WEST) &&
           AITile.IsBuildable(tile + SOUTH + WEST);
}

function BuildHQ() {
    /* Check if we have HQ already built. */
    if(AICompany.GetCompanyHQ(AICompany.COMPANY_SELF) != AIMap.TILE_INVALID)
        return true;

    /* Get towns we have presence in (we have already built a tram stop). */
    local towns = AITownList();
    towns.Valuate(AITown.GetRating, AICompany.COMPANY_SELF);
    towns.RemoveValue(AITown.TOWN_RATING_NONE);
    towns.RemoveValue(AITown.TOWN_RATING_INVALID);
    towns.Valuate(AITown.GetPopulation);
    towns.Sort(AIList.SORT_BY_VALUE, AIList.SORT_DESCENDING);

    for(local town = towns.Begin(); !towns.IsEnd(); town = towns.Next()) {
        /* Get tiles around town center sorted by distance. */
        local town_center = AITown.GetLocation(town);
        local location = AITileList();
        SafeAddRectangle(location, town_center, 20);
        location.Valuate(_val_CanHaveHQ);
        location.KeepValue(1);
        if(location.IsEmpty())
            continue;
        location.Valuate(AITile.GetDistanceSquareToTile, town_center);
        location.Sort(AIList.SORT_BY_VALUE, AIList.SORT_ASCENDING);

        if(AICompany.BuildCompanyHQ(location.Begin())) {
            AILog.Info("Building HQ in " + AITown.GetName(town));
            return true;
        }
    }

    return false;
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

