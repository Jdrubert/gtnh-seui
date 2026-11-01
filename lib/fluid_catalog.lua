-- GTNH 2.9.0-RC-1 Space Drilling Module catalog of all 40 fluids
-- Routes and base extraction rates come from GT5-Unofficial 5.09.54.183 SpacePumpingRecipes (identical to 5.09.52.594).

local M = {}

M.entries = {
  {2,1,"Chlorobenzene",896000,{"chlorobenzene"}},
  {3,1,"Ender Goo",32000,{"endergoo","ender_goo"}},
  {3,2,"Extra Heavy Oil",1400000,{"oil.extraheavy","extraheavyoil","heavy_oil"}},
  {3,3,"Lava",1800000,{"lava"}},
  {3,4,"Natural Gas",1400000,{"naturalgas","natural_gas"}},
  {4,1,"Sulfuric Acid",784000,{"sulfuricacid","sulfuric_acid"}},
  {4,2,"Molten Iron",896000,{"molten.iron","molten_iron"}},
  {4,3,"Oil",1400000,{"oil"}},
  {4,4,"Heavy Oil",1792000,{"oilheavy","heavy_oil"}},
  {4,5,"Molten Lead",896000,{"molten.lead","molten_lead"}},
  {4,6,"Raw Oil",1400000,{"oilmedium","raw_oil"}},
  {4,7,"Light Oil",780000,{"oillight","light_oil"}},
  {4,8,"Carbon Dioxide",1680000,{"carbondioxide","carbon_dioxide"}},
  {5,1,"Carbon Monoxide",4480000,{"carbonmonoxide","carbon_monoxide"}},
  {5,2,"Helium-3",2800000,{"helium-3","helium3"}},
  {5,3,"Salt Water",2800000,{"saltwater","salt_water"}},
  {5,4,"Helium",1400000,{"helium"}},
  {5,5,"Liquid Oxygen",896000,{"liquidoxygen","liquid_oxygen"}},
  {5,6,"Neon",32000,{"neon"}},
  {5,7,"Argon",32000,{"argon"}},
  {5,8,"Krypton",8000,{"krypton"}},
  {5,9,"Methane",1792000,{"methane"}},
  {5,10,"Hydrogen Sulfide",392000,{"hydrogensulfide","hydrogen_sulfide"}},
  {5,11,"Ethane",1194000,{"ethane"}},
  {6,1,"Deuterium",1568000,{"deuterium"}},
  {6,2,"Tritium",240000,{"tritium"}},
  {6,3,"Ammonia",240000,{"ammonia"}},
  {6,4,"Xenon",16000,{"xenon"}},
  {6,5,"Ethylene",1792000,{"ethylene"}},
  {7,1,"Hydrofluoric Acid",672000,{"hydrofluoricacid","hydrofluoric_acid"}},
  {7,2,"Fluorine",1792000,{"fluorine"}},
  {7,3,"Nitrogen",1792000,{"nitrogen"}},
  {7,4,"Oxygen",1792000,{"oxygen"}},
  {8,1,"Hydrogen",1568000,{"hydrogen"}},
  {8,2,"Liquid Air",875000,{"liquidair","liquid_air"}},
  {8,3,"Molten Copper",672000,{"molten.copper","molten_copper"}},
  {8,4,"Unknown Liquid",672000,{"unknowwater","unknown_liquid"}},
  {8,5,"Distilled Water",17920000,{"ic2distilledwater","distilledwater","distilled_water"}},
  {8,6,"Radon",64000,{"radon"}},
  {8,7,"Molten Tin",672000,{"molten.tin","molten_tin"}},
}

function M.routeKey(planet, gas)
  return tostring(tonumber(planet) or 0) .. ":" .. tostring(tonumber(gas) or 0)
end

function M.populate(model)
  -- Older versions re-added the whole catalog unconditionally on every start, which made the list in seui.dat double each time.
  -- Here we first remove duplicates among the loaded targets by routeKey (keep the first one, merge sourceRef),
  -- then fill in any entries missing from the catalog. Old entries without route info ("0:0") are not deduplicated, to avoid wrongly merging different fluids.
  local existing = {}
  local duplicateIds = {}
  for _, t in ipairs(model.getTargets()) do
    if t.domain == "pump" and t.route then
      local key = M.routeKey(t.route.planetType, t.route.gasType)
      if key ~= "0:0" then
        local prev = existing[key]
        if prev then
          if not prev.sourceRef and t.sourceRef then prev.sourceRef = t.sourceRef end
          table.insert(duplicateIds, t.id)
        else
          existing[key] = t
        end
      end
    end
  end
  local removed = 0
  for _, id in ipairs(duplicateIds) do
    if model.removeById(id) then removed = removed + 1 end
  end

  local added = 0
  for order, e in ipairs(M.entries) do
    local planet, gas, label, rate, aliases = e[1],e[2],e[3],e[4],e[5]
    local found = existing[M.routeKey(planet, gas)]
    if found then
      found.fluidAliases = found.fluidAliases or aliases
      found.route.baseRate = found.route.baseRate or rate
    else
      model.addTarget{
        id="pump:"..planet..":"..gas, domain="pump", label=label,
        fluid=aliases[1], fluidAliases=aliases, mode="OFF", target=0,
        order=order, route={planetType=planet,gasType=gas,baseRate=rate,maxBatch=30},
      }
      added=added+1
    end
  end
  return added, removed
end

return M
