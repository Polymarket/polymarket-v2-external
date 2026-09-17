import "summaries/Exchange_base_summaries.spec";
import "summaries/Exchange_call_resolution.spec";
//use builtin rule sanity;

// turns out some codes do have an 'f'! e.g. Cork
rule sanity {
    env e;
    calldataarg args;
    method certoraF;
    certoraF(e, args);
    satisfy true, "sanity check failed";
}