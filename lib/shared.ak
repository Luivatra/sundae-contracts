use aiken/builtin
use aiken/collection/dict.{Dict}
use aiken/collection/list
use aiken/crypto.{Blake2b_256, Hash}
use aiken/primitive/bytearray
use cardano/address.{Credential, Script}
use cardano/assets.{AssetName, PolicyId, Value, ada_policy_id}
use cardano/transaction.{
  DatumHash, InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
  find_input,
}
use tests/examples/ex_shared.{
  mk_output_reference, script_address, wallet_address,
}

/// An alias type for the pool identifier, to make it slightly easier to reason about
pub type Ident =
  ByteArray

/// An asset class is a combination of a policy ID and asset name; uniquely identifies one type of token, useful to make the code more readable
pub type AssetClass =
  (PolicyId, AssetName)

/// A rational number, represented as the numerator and denominator
pub type Rational =
  (Int, Int)

/// A "value" for which we know there is only one value; convenient for performance reasons, and to make the code more readable
pub type SingletonValue =
  (PolicyId, AssetName, Int)

/// Convert a singleton value to an actual value; convenient for comparing or adding together values
pub fn to_value((p, a, i): SingletonValue) -> assets.Value {
  assets.from_asset(p, a, i)
}

/// Find the datum for a specific output
/// That is, the datum may either be in the output itself, as a datum hash
/// or in the transaction witnesses, which are passed in here
/// We don't use this everywhere, but we use it for orders in particular because
/// that lets us compose with other protocols (another protocol can produce an non-inline datum, and it can still be scooped)
/// Provided the scooper knows about the datum itself
pub fn datum_of(
  datums: Dict<Hash<Blake2b_256, Data>, Data>,
  output: Output,
) -> Option<Data> {
  when output.datum is {
    transaction.NoDatum -> None
    transaction.DatumHash(h) -> dict.get(datums, h)
    transaction.InlineDatum(d) -> Some(d)
  }
}

/// Check that the UTXO contents are correct given a specific pool outcome
/// In particular, it must have the final A reserves, the final B reserves, the pool NFT, and the protocol fees
pub fn has_expected_pool_value(
  pool_script_hash: PolicyId,
  identifier: Ident,
  output_value: Value,
  pool_policy_a: PolicyId,
  pool_asset_name_a: AssetName,
  pool_quantity_a: Int,
  pool_policy_b: PolicyId,
  pool_asset_name_b: AssetName,
  pool_quantity_b: Int,
  final_lp: Int,
  final_protocol_fees: Int,
) -> Bool {
  // Asset A *could* be ADA; in which case there should be 3 tokens on the output
  // (ADA, Asset B, and the NFT)
  if pool_policy_a == ada_policy_id {
    let actual =
      list.foldl(
        assets.flatten(output_value),
        // (token count, lovelace amount, token b amount, pool nft amount)
        (0, 0, 0, 0),
        fn(asset, acc) {
          let token_count = acc.1st + 1
          if asset.1st == pool_policy_a {
            (token_count, acc.2nd + asset.3rd, acc.3rd, acc.4th)
          } else if asset.1st == pool_policy_b && asset.2nd == pool_asset_name_b {
            (token_count, acc.2nd, acc.3rd + asset.3rd, acc.4th)
          } else {
            expect asset == (pool_script_hash, pool_nft_name(identifier), 1)
            (token_count, acc.2nd, acc.3rd, acc.4th + 1)
          }
        },
      )
    // If we're withdrawing the last bit of liquidity, we just have ADA and the pool token
    let expected =
      if final_lp == 0 {
        expect pool_quantity_a == 0
        expect pool_quantity_b == 0
        (2, final_protocol_fees, 0, 1)
      } else {
        (3, final_protocol_fees + pool_quantity_a, pool_quantity_b, 1)
      }
    // Rather than constructing a value directly (which can be expensive)
    // we can just compare the expected token count and amounts with a single pass over the value
    expected == actual
  } else {
    // Asset A isn't ADA, Asset B will *never* be ADA; in this case, there should be 4 tokens on the output:
    // ADA, the Pool NFT, Asset A, and Asset B
    let actual =
      list.foldl(
        assets.flatten(output_value),
        // (token count, lovelace amount, token a amount, token b amount, pool nft amount)
        (0, 0, 0, 0, 0),
        fn(asset, acc) {
          let token_count = acc.1st + 1
          if asset.1st == ada_policy_id {
            (token_count, acc.2nd + asset.3rd, acc.3rd, acc.4th, acc.5th)
          } else if asset.1st == pool_policy_a && asset.2nd == pool_asset_name_a {
            (token_count, acc.2nd, acc.3rd + asset.3rd, acc.4th, acc.5th)
          } else if asset.1st == pool_policy_b && asset.2nd == pool_asset_name_b {
            (token_count, acc.2nd, acc.3rd, acc.4th + asset.3rd, acc.5th)
          } else {
            expect asset == (pool_script_hash, pool_nft_name(identifier), 1)
            (token_count, acc.2nd, acc.3rd, acc.4th, acc.5th + 1)
          }
        },
      )
    // If we're withdrawing the last bit of liquidity, we just have ADA and the pool token
    let expected =
      if final_lp == 0 {
        expect pool_quantity_a == 0
        expect pool_quantity_b == 0
        (2, final_protocol_fees, 0, 0, 1)
      } else {
        (4, final_protocol_fees, pool_quantity_a, pool_quantity_b, 1)
      }
    expected == actual
  }
}

/// Find the **input** (which was the output of some other transaction) for which we're actually evaluating the script to determine if it is spendable
/// Also called "own_input" in places
pub fn spent_output(
  transaction: Transaction,
  out_ref: OutputReference,
) -> Output {
  expect Some(input) = find_input(transaction.inputs, out_ref)
  input.output
}

/// Find the index of the given "out_ref"; confusingly, this is the  the inputs, not the outputs
pub fn own_input_index(
  transaction: Transaction,
  out_ref: OutputReference,
) -> Int {
  do_own_input_index(transaction.inputs, out_ref, 0)
}

pub fn do_own_input_index(
  inputs: List<Input>,
  output_reference: OutputReference,
  i: Int,
) -> Int {
  expect [input, ..rest] = inputs
  if input.output_reference == output_reference {
    i
  } else {
    do_own_input_index(rest, output_reference, i + 1)
  }
}

/// Find a specific input index, and validate that it has at least one of the specified token
/// Useful for looking up the pool token, etc.
/// NOTE: this is actually unused, because we chose to go with the optimization in the body
pub fn get_input_with_token(
  /// The list of transaction inputs
  inputs: List<Input>,
  /// The index at which we should expect the input
  idx: Int,
  /// The token we expect to find on the UTXO
  token: AssetClass,
) -> Output {
  // Optimization: assume first reference input by farming for high reference script hashes
  expect Some(input) = list.at(inputs, idx)
  expect assets.quantity_of(input.output.value, token.1st, token.2nd) >= 1
  input.output
}

/// A more permissive version of get_input_with_token, where we don't know the index to expect the input at
/// NOTE: this is actually unused
pub fn find_input_with_token(inputs: List<Input>, token: AssetClass) -> Output {
  expect Some(input) =
    list.find(
      inputs,
      fn(input) {
        assets.quantity_of(input.output.value, token.1st, token.2nd) >= 1
      },
    )
  input.output
}

// We need to count the number of input orders to enforce that every order is "considered"
// however, we don't know the order script address (indeed, there could be many types!);
// and for efficiency, we don't want to do an equality comparison each time anyway
// So, we use a clever trick, and count the number of *script* addresses, and subtract the constant below.
// This relies on a delicate confluence of factors that should be reconsidered very carefully in the final version:
// - There is an exact number of "non-order" scripts that will be in each transaction
// - The number of entries in the input order map is checked against this count of orders
// - We force each entry in the input order map to be unique
// - We force the script to evaluate each entry in the order map as an order
// - If the input can't be processed as an order (ex: it has a incompatible datum, or enforces different logic)
//   the script will fail
// For example, if someone included two pools, then either:
// - the input list will leave it off, failing the check for number of orders
// - the input list will include an order twice to make the counts match, but failing the uniqueness check
// - the input list will include the pool script, which will fail to parse
const exact_non_order_script_inputs = 1

/// Check whether a specific credential is a script credential; this can be useful for identifying pool and order scripts,
/// even if we don't know what the specific hash is going to be
pub fn is_script(credential: Credential) -> Bool {
  when credential is {
    Script(_) -> True
    _ -> False
  }
}

/// Count the number of orders on the inputs,
/// without knowing the exact script address they will use
/// This is quite subtle, so see the note above
pub fn count_orders(tx_inputs: List<Input>) -> Int {
  when tx_inputs is {
    // Note: by using  -exact_non_order_script_inputs for the base case,
    // it's equivalent to subtracting at the end
    [] -> -exact_non_order_script_inputs
    [input, ..rest] ->
      // The reason this is important is twofold:
      // - We count them in the first place to ensure that we process every order by the end of the transaction
      // - and we compare the script this way so that if we implement a new order script, with additional logic,
      //   and the correct datum format, it can be processed the pool just fine
      when input.output.address.payment_credential is {
        Script(_) -> count_orders(rest) + 1
        _ -> count_orders(rest)
      }
  }
}

// Taken from unmerged PR: https://github.com/aiken-lang/stdlib/pull/73/files
pub fn is_sqrt(self: Int, x: Int) -> Bool {
  x * x <= self && ( x + 1 ) * ( x + 1 ) > self
}

test is_sqrt1() {
  is_sqrt(44203, 210)
}

test is_sqrt2() {
  is_sqrt(975461057789971041, 987654321)
}

/// Check whether a specific value has *exactly* the right amount of tokens
/// This is important to, for example, efficiently check the pool output has the correct value
/// Check where this is used, because it's a very subtle bit of logic for where this is safe to do
pub fn has_exact_token_count(val: assets.Value, count: Int) {
  count == list.foldl(
    // Convert the value to a list, so we can fold over it
    dict.to_pairs(assets.to_dict(val)),
    0,
    fn(tk_pair, total) {
      // The first fold is over the list of policy IDs
      // and the second fold is over the list of tokens
      // so we can count the distinct Asset IDs
      // TODO: can we just use list.length here?
      list.foldl(
        dict.to_pairs(builtin.snd_pair(tk_pair)),
        0,
        fn(_tn, tn_length) { tn_length + 1 },
      ) + total
    },
  )
}

test test_has_exact_token_count() {
  let val =
    assets.from_lovelace(100)
      |> assets.add("abc", "def", 100)
      |> assets.add("xyz", "www", 200)
  expect has_exact_token_count(val, 3)

  let val =
    assets.from_lovelace(100)
      |> assets.add("abc", "def", 100)
  expect has_exact_token_count(val, 2)

  let val =
    assets.from_lovelace(100)
      |> assets.add("abc", "def", 100)
  expect !has_exact_token_count(val, 3)
  True
}

/// The CIP-68 (100) "reference" token for a given pool identifier; this token lets you set the metadata like the name, decimals, image, etc.
/// See https://github.com/cardano-foundation/CIPs/tree/master/CIP-0068 for more details on the specific prefix
pub fn pool_ref_name(pool_ident: Ident) {
  bytearray.concat(#"000643b0", pool_ident)
}

/// The CIP-68 (222) "nft" token for a given pool identifier; this token is an NFT used to track the actual swappable funds in the pool
pub fn pool_nft_name(pool_ident: Ident) {
  bytearray.concat(#"000de140", pool_ident)
}

/// The CIP-68 (333) "fungible" token for a given pool identifier; this token is used to track a percentage ownership of funds in a given pool
pub fn pool_lp_name(pool_ident: Ident) {
  bytearray.concat(#"0014df10", pool_ident)
}

/// Construct all three pool token names
/// This is a minor convenience; theoretically it would be more efficient to construct each independently,
/// but this is likely so small as to not be worth sacrificing the performance
/// Note: it's important to pay attention to the order of the token names returned, because they're indistinguishable to the caller!
pub fn pool_token_names(pool_ident: Ident) {
  (
    pool_ref_name(pool_ident),
    pool_nft_name(pool_ident),
    pool_lp_name(pool_ident),
  )
}

// Test for count_orders, with 16 inputs of which 10 are orders.
test count_orders_test() {
  let hash_of_pool_script =
    #"00000000000000000000000000000000000000000000000000000000"
  let pool_address = script_address(hash_of_pool_script)
  let pool_input =
    Input {
      output_reference: mk_output_reference(0),
      output: Output {
        address: pool_address,
        value: assets.from_lovelace(0),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let hash_of_escrow_script =
    #"00000000000000000000000000000000000000000000000000000000"
  let escrow_address = script_address(hash_of_escrow_script)
  let escrow1_in =
    Input {
      output_reference: mk_output_reference(2),
      output: Output {
        address: escrow_address,
        value: assets.from_lovelace(0),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let escrow2_in =
    Input {
      output_reference: mk_output_reference(3),
      output: Output {
        address: escrow_address,
        value: assets.from_lovelace(0),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let other_address =
    wallet_address(#"fede0000000000000000000000000000000000000000000000000000")
  let other_in =
    Input {
      output_reference: mk_output_reference(4),
      output: Output {
        address: other_address,
        value: assets.from_lovelace(0),
        datum: NoDatum,
        reference_script: None,
      },
    }

  let inputs =
    [
      pool_input, other_in, escrow1_in, escrow2_in, other_in, escrow1_in,
      escrow2_in, other_in, escrow1_in, escrow2_in, other_in, escrow1_in,
      escrow2_in, other_in, escrow1_in, escrow2_in,
    ]

  count_orders(inputs) == 10
}

pub fn oracle_sft_name() {
  "oracle"
}

pub fn fees_in_legal_range(fees: Int) {
  and {
    fees >= 0,
    fees <= 10000,
  }
}
