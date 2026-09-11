
	*===============================================================================
	* CODING_SAMPLE.DO
	*-------------------------------------------------------------------------------
	/*
	Author: Luigi Vicencio
	Last updated: September 11, 2026

	- This .do file combines some .do files of my Honours Economics Thesis,
	"Voters Know the Difference: National Shocks and Local Accountability in Brazil."

	- You can read my thesis here: https://github.com/luigivicencio/luigi-predoc/blob/4562a2735ccee4f370183d953d6245261ff240cf/honours_thesis_vicencio.pdf

	- Question: does a municipality's exposure to the 2013-2016 Brazilian
	recession, which is measured by a Bartik shift-share instrument built from
	pre-recession (Census) industry employment shares interacted with
	national sectoral employment shifts, influence the change in the incumbent
	mayor's vote share, or the change in the incumbent party's vote share,
	between the 2012 and 2016 municipal elections?

	- Structure:
		Part 1  Build the Bartik shift-share instrument
		Part 2  Clean the mayoral election panel, and build outcomes
		Part 3  Import municipal control variables
		Part 4  Merge, run regressions, and export table and figure

	- This project follows a standard Input, Code, Temp, Output, Log structure of folders

	- Paths below are relative to this file's own folder (Code/). Before running, 
	 set your working directory there, e.g.:
	   cd ".../Honours Thesis/Code_Sample/Code"
	   do "coding_sample.do"
	   
	- Requires: esttab (SSC: ssc install estout) for the regression table

	- AI Acknowledgement: I used Claude Code to help me with the code to define re-election, 
	combine different .do files, write additional documentation and plotting
	
	*/
	*===============================================================================

	clear all
	set more off

	* Project folders, relative to Code/ (this file's folder)
	global input_dir  "../Input"
	global temp_dir   "../Temp"
	global output_dir "../Output"
	global log_dir    "../Log"

	cap log close
	log using "$log_dir/coding_sample.log", replace text

	*===============================================================================
	**# PART 1: BUILD THE BARTIK SHIFT-SHARE INSTRUMENT
	*-------------------------------------------------------------------------------
	/*
	- For each municipality, construct its local exposure to the national employment shift
	as the sum, across industries k, of the national employment shift for industry k times
	the municipality's baseline employment share in industry k.

	- Data Sources
		- National Employment Shift: Log difference (growth rate) between formal employment
		2016 and 2012 from RAIS
		(retrieved from Base dos Dados using Big Query: https://basedosdados.org/dataset/3e7c4d58-96ba-448e-b053-d385a829ef00?table=dabe5ea8-3bb5-4a3e-9d5a-3c7003cd4a60)
		- Employment Share: Share of (formal and informal) employment from Census 2010
		(retrieved from Base dos Dados using Big Query: https://basedosdados.org/dataset/b8e8bd62-4eb9-42f9-9ffa-b5cca093f58e?table=5645c1d7-9749-4b9a-b6d2-7f1b5d43038a)
		
	- National shift is computed leave-one-out (excluding the municipality's own employment) 
	so that a single large municipality cannot mechanically drive its own instrument.

	- Inputs  : $input_dir/shift_share/concordance_mapping_census_labor.csv
	             (crosswalk from the Census industry classification to the
	             labor-market survey's industry classification)
	           $input_dir/shift_share/census_employment.csv
	             (Census employment by municipality x industry, baseline year in 2010)
	           $input_dir/shift_share/labor_employment.csv
	             (labor-market survey employment by municipality x industry,
	             2012 and 2016)
				 
	- Output  : $temp_dir/shift_share.dta (one row per municipality)
	*/
	*===============================================================================

	* Step 1.1: Import the industry concordance
	import delimited "$input_dir/shift_share/concordance_mapping_census_labor.csv", clear
	tempfile concordance
	save `concordance'

	* Step 1.2: Import Census employment (baseline 2010 industry mix)
	import delimited "$input_dir/shift_share/census_employment.csv", clear
	tempfile census_employment
	save `census_employment'

	* Step 1.3: Import labor-market employment, 2012 and 2016
	import delimited "$input_dir/shift_share/labor_employment.csv", clear

	* Step 1.4: Apply the concordance so both datasets share one industry code
	merge m:1 labor_industry_code using `concordance'
	keep if _merge == 3
	drop _merge

	* Step 1.5: Merge onto Census baseline employment
	merge 1:1 municipality_id census_industry_code using `census_employment'
	keep if _merge == 3
	drop _merge

	* Step 1.6: Baseline industry share within each municipality
	gen census_share = employed_workers / total_employed

	* Step 1.7: National (leave-one-out) industry growth, 2016 - 2012
	bysort census_industry_code: egen national_employment_2012 = total(employment_2012)
	bysort census_industry_code: egen national_employment_2016 = total(employment_2016)

	gen national_employment_2012_loo = national_employment_2012 - employment_2012
	gen national_employment_2016_loo = national_employment_2016 - employment_2016

	gen industry_shift = ln(national_employment_2016_loo) - ln(national_employment_2012_loo)

	* Step 1.8: Bartik component = baseline share x national shift
	gen bartik_component = census_share * industry_shift

	* Step 1.9: Aggregate to the municipality level (sum across industries)
	bysort municipality_id: egen shift_share = total(bartik_component)
	label var shift_share "Bartik shift-share instrument, 2016-2012 (log)"

	* Step 1.10: Collapse to one row per municipality and save
	keep municipality_id shift_share
	duplicates drop municipality_id, force

	save "$temp_dir/shift_share.dta", replace

	*===============================================================================
	**# PART 2: CLEAN THE MAYORAL ELECTION PANEL, BUILD OUTCOMES
	*-------------------------------------------------------------------------------
	/*
	- HOW MAYORAL RE-ELECTION WORKS IN BRAZIL (context for the code below)
		- Mayors serve 4-year terms. Elections are held every 4 years nationwide
		  (2008, 2012, 2016, ...).
		- An incumbent may run for one immediately consecutive re-election, 
		  then must sit out at least one term ("lame duck") before running again. 
		  A term-limited mayor simply does not appear as a candidate in the following 
		  election
		- In municipalities above ~200,000 registered voters, if no candidate wins
		  more than 50% of valid votes in the first round (round == 1), the top
		  two candidates go to a runoff (round == 2). result == "elected"
		  identifies the eventual winner regardless of how many rounds were needed.
		  Vote shares below are computed from round 1 only, so they are
		  comparable across municipalities regardless of whether a runoff occurred.
		- voter_id identifies the same person across elections and parties,
		  which is what makes it possible to track whether the same incumbent
		  ran again, independent of party affiliation.

	- Outcomes built here measure change in vote share:
		- mayor_delta : change in the 2012 incumbent's own first-round vote
	                share, 2016-2012 (missing if that person did not run
	                again in 2016)
		- party_delta : change in the 2012-winning party's first-round vote
	                share, 2016-2012, regardless of which candidate ran
	                for it (missing if that party fielded no one in 2016)
	
	- Data Source: Candidate-level data is available at TSE (Electoral Court) 
	(retrieved from Base dos Dados using Big Query: https://basedosdados.org/dataset/eef764df-bde8-4905-b115-6fc23b6ba9d6?table=2e204854-e453-4257-9fef-5e10f3ff1f56)

	- Input  : $input_dir/elections/elections.csv (candidate-level panel,
	         2012 and 2016 mayoral elections)
	- Output : $temp_dir/elections.dta (one row per municipality, 2016 election)
	*/
	*===============================================================================

	import delimited "$input_dir/elections/elections.csv", clear

	* Step 2.1: Who won in 2012 -- person (voter_id) and party
	gen winning_voter_id_2012 = voter_id if year == 2012 & result == "elected"
	gen winning_party_2012    = party    if year == 2012 & result == "elected"
	bysort municipality_id: egen voter_id_2012 = mode(winning_voter_id_2012), maxmode
	bysort municipality_id: egen party_2012    = mode(winning_party_2012), maxmode

	* Step 2.2: First-round vote share for every candidate
	bysort municipality_id year: egen total_votes_round1 = total(votes) if round == 1
	bysort municipality_id year: egen total_votes_round1_fill = max(total_votes_round1)
	gen vote_share_round1 = (votes / total_votes_round1_fill) * 100 if round == 1

	* Propagate each candidate's round-1 vote share to their round-2 row, if any
	bysort municipality_id year voter_id: egen vote_share = max(vote_share_round1)

	* Baseline: the 2012 winner's own first-round vote share
	gen winning_vote_share_2012 = vote_share if year == 2012 & result == "elected"
	bysort municipality_id: egen baseline_vote_share = max(winning_vote_share_2012)

	* Step 2.3: Mayor's change in vote share, 2016-2012 
	gen mayor_vote_share_delta = vote_share - baseline_vote_share if ///
		year == 2016 & voter_id == voter_id_2012 & !missing(voter_id_2012)
	bysort municipality_id year: egen mayor_delta = max(mayor_vote_share_delta)
	label var mayor_delta "Change in incumbent mayor's vote share, 2016-2012 (pp)"

	* Step 2.4: Party's change in vote share, 2016-2012 
	gen party_vote_share_delta = vote_share - baseline_vote_share if ///
		year == 2016 & party == party_2012 & !missing(party_2012)
	bysort municipality_id year: egen party_delta = max(party_vote_share_delta)
	label var party_delta "Change in the 2012-winning party's vote share, 2016-2012 (pp)"

	* Step 2.5: Keep one row per municipality (the 2016 winner) and save
	keep if year == 2016 & result == "elected"
	keep municipality_id state mayor_delta party_delta
	duplicates drop municipality_id, force

	save "$temp_dir/elections.dta", replace


	*===============================================================================
	**# PART 3: IMPORT MUNICIPAL CONTROL VARIABLES
	*-------------------------------------------------------------------------------
	/*
	- Data source: Demographic controls from Census 2010
	(retrieved from Base dos Dados using Big Query: https://basedosdados.org/dataset/b8e8bd62-4eb9-42f9-9ffa-b5cca093f58e?table=5645c1d7-9749-4b9a-b6d2-7f1b5d43038a)
	
	- Controls: share of rural population, share of male population,
	share of non-white population, and average income per capita
	
	- Input  : $input_dir/controls/municipal_controls.csv (already cleaned,
	         one row per municipality)
	- Output : $temp_dir/controls.dta
	*/
	*===============================================================================

	import delimited "$input_dir/controls/municipal_controls.csv", clear
	save "$temp_dir/controls.dta", replace


	*===============================================================================
	**# PART 4: MERGE, RUN REGRESSIONS, EXPORT TABLE + FIGURE
	*-------------------------------------------------------------------------------
	/*
	Inputs  : $temp_dir/shift_share.dta, $temp_dir/elections.dta, $temp_dir/controls.dta
	Outputs : $temp_dir/merged_analysis.dta
	          $output_dir/Tables/results_main.tex
	          $output_dir/Figures/coefplot_vote_share_delta.png
	*/
	*===============================================================================

	* Step 4.1: Merge the three analysis-ready datasets on municipality_id
	use "$temp_dir/elections.dta", clear

	merge 1:1 municipality_id using "$temp_dir/shift_share.dta"
	tab _merge
	keep if _merge == 3
	drop _merge

	merge 1:1 municipality_id using "$temp_dir/controls.dta"
	tab _merge
	keep if _merge == 3
	drop _merge

	encode state, gen(state_id)

	save "$temp_dir/merged_analysis.dta", replace

	* Step 4.2: Regressions: change in mayor and party vote share
	* Regression without controls, with controls and with controls + state FE. Robust SE
	* Two outcome variables: mayor's change in vote share and party's change in vote share
	
	* Control variables
	global controls "share_rural share_male share_nonwhite average_income"

	eststo clear

	eststo m1: reg mayor_delta shift_share, robust
	eststo m2: reg mayor_delta shift_share $controls, robust
	eststo m3: reg mayor_delta shift_share $controls i.state_id, robust

	eststo p1: reg party_delta shift_share, robust
	eststo p2: reg party_delta shift_share $controls, robust
	eststo p3: reg party_delta shift_share $controls i.state_id, robust

	esttab m1 m2 m3 p1 p2 p3 using "$output_dir/Tables/results_main.tex", ///
		b(3) se(3) star(* 0.10 ** 0.05 *** 0.01) ///
		keep(shift_share) ///
		mtitles("Mayor: No Controls" "Mayor: Controls" "Mayor: Controls + FE" ///
				 "Party: No Controls" "Party: Controls" "Party: Controls + FE") ///
		scalars(N r2) replace

	* Step 4.3: Coefficient plot: shift-share coefficient by specification
	foreach spec in m1 m2 m3 {
		estimates restore `spec'
		local b_`spec'  = _b[shift_share]
		local se_`spec' = _se[shift_share]
	}
	foreach spec in p1 p2 p3 {
		estimates restore `spec'
		local b_`spec'  = _b[shift_share]
		local se_`spec' = _se[shift_share]
	}

	preserve
	clear
	set obs 6

	gen spec   = .
	gen series = .   // 1 = Mayor Vote Share Delta, 2 = Party Vote Share Delta
	gen coef   = .
	gen lo     = .
	gen hi     = .

	local i = 1
	foreach spec in m1 m2 m3 {
		replace spec   = `i' in `i'
		replace series = 1   in `i'
		replace coef   = `b_`spec''                          in `i'
		replace lo     = `b_`spec'' - 1.96*`se_`spec''        in `i'
		replace hi     = `b_`spec'' + 1.96*`se_`spec''        in `i'
		local ++i
	}
	foreach spec in p1 p2 p3 {
		replace spec   = `i' - 3 in `i'
		replace series = 2       in `i'
		replace coef   = `b_`spec''                          in `i'
		replace lo     = `b_`spec'' - 1.96*`se_`spec''        in `i'
		replace hi     = `b_`spec'' + 1.96*`se_`spec''        in `i'
		local ++i
	}

	* Organize the two series so they don't overlap on the same position
	gen spec_org = spec - 0.1 if series == 1
	replace spec_org = spec + 0.1 if series == 2

	twoway ///
		(rcap    lo hi spec_org if series == 1, lcolor("#223868") lwidth(thick)) ///
		(scatter coef spec_org  if series == 1, msymbol(O) mcolor("#223868") msize(large)) ///
		(rcap    lo hi spec_org if series == 2, lcolor("#397844") lwidth(thick)) ///
		(scatter coef spec_org  if series == 2, msymbol(S) mcolor("#397844") msize(large)) ///
		, ///
		yline(0, lcolor(black) lpattern(dash) lwidth(thin)) ///
		xlabel(1 "No Controls" 2 "+ Controls" 3 "+ Controls + State FE", noticks labsize(medlarge)) ///
		xscale(range(0.5 3.5)) ///
		ylabel(, labsize(medlarge) angle(0)) ///
		ytitle("Coefficient on Shift-Share Shock" "(pp change in vote share)", size(medlarge)) ///
		xtitle("") ///
		legend(order(2 "{&Delta} Mayor Vote Share" 4 "{&Delta} Party Vote Share") pos(12) ring(1) col(2) size(medlarge)) ///
		graphregion(color(white)) bgcolor(white)

	graph export "$output_dir/Figures/coefplot_vote_share_delta.png", replace width(3000)
	restore

	log close

