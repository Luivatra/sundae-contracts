{-# OPTIONS_GHC -fno-unbox-small-strict-fields #-}

module Sundae.Contracts.Common where

import qualified Prelude
import PlutusTx.Prelude
import PlutusTx.Sqrt
import Data.Aeson (FromJSON(..), ToJSON(..), withScientific)

import qualified Ledger.Typed.Scripts as Scripts
import Plutus.V1.Ledger.Api
import Plutus.V1.Ledger.Value
import Plutus.V1.Ledger.Time

import Ledger hiding (mint, fee, singleton, inputs, validRange)
import qualified PlutusTx
import qualified PlutusTx.AssocMap as Map
import PlutusTx.Ratio

import GHC.Generics
import Control.DeepSeq
import Sundae.Utilities

-- | Factory script controls creation of pools
data Factory

-- | The dead factory script holds adopted proposal data for upgrading pools
data DeadFactory

-- | Script that holds all live pools
data Pool

-- | Script that holds all dead pools
data DeadPool

-- | Script that holds scooper licenses
data ScooperFeeHolder

-- | Script that holds all escrows
data Escrow

-- | Script that adjudicates protocol assets
data Treasury

-- | Script that holds an approved proposal before it's been used to upgrade the factory
data Proposal

-- | Holds gifts to the treasury, before they've been approved
data Gift

-- | A single UTXO that uniquely identifies / parameterizes the entire protocol
-- | This ensures that anyone who runs our scripts with a different UTXO
-- | ends up with different policy IDs / script hashes, and is a fundamentally different protocol
newtype ProtocolBootUTXO = ProtocolBootUTXO
  { unProtocolBootUTXO :: TxOutRef
  }
  deriving stock (Generic, Prelude.Show)
  deriving newtype (FromJSON, ToJSON)

-- | Used to make the treasury token an NFT.
newtype TreasuryBootSettings = TreasuryBootSettings
  { treasury'protocolBootUTXO :: ProtocolBootUTXO
  }
  deriving newtype (FromJSON, ToJSON)

data FactoryBootSettings
  = BrandNewFactoryBootSettings
  { factory'protocolBootUTXO :: ProtocolBootUTXO
  , initialLegalScoopers :: [PubKeyHash]
  }
  | UpgradedFactoryBootSettings
  { oldFactoryBootCurrencySymbol :: OldFactoryBootCurrencySymbol
  }
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (FromJSON, ToJSON)

data UpgradeSettings = UpgradeSettings
  { upgradeTimeLockPeriod :: DiffMilliSeconds
  , upgradeAuthentication :: AssetClass
  }
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The destination for the results of an escrowed operation.
-- Could be a user address, but could also be a script address + datum
-- for composing with other protocols.
data EscrowDestination = EscrowDestination !Address !(Maybe DatumHash)
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq EscrowDestination where
  {-# inlinable (==) #-}
  (==) (EscrowDestination addr1 dh1) (EscrowDestination addr2 dh2) =
    addr1 == addr2 && dh1 == dh2

-- | An escrow's address information.
-- The first field is the destination for the results of the escrowed operation.
-- The second field can also supply auxiliary PubKeyHash which can be used to authenticate cancelling this order.
data EscrowAddress = EscrowAddress !EscrowDestination !(Maybe PubKeyHash)
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq EscrowAddress where
  {-# inlinable (==) #-}
  (==) (EscrowAddress dest1 pkh1) (EscrowAddress dest2 pkh2) =
    dest1 == dest2 && pkh1 == pkh2

{-# inlinable escrowPubKeyHashes #-}
escrowPubKeyHashes :: EscrowAddress -> [PubKeyHash]
escrowPubKeyHashes (EscrowAddress (EscrowDestination addr _) mPubKey) =
  mapMaybe id [toPubKeyHash addr, mPubKey]

{-# inlinable fromEscrowAddress #-}
fromEscrowAddress :: EscrowAddress -> EscrowDestination
fromEscrowAddress (EscrowAddress dest _) = dest

newtype SwapFees = SwapFees Rational
  deriving newtype (PlutusTx.ToData, PlutusTx.FromData, PlutusTx.UnsafeFromData, Eq, NFData)
  deriving (Prelude.Show)

instance FromJSON SwapFees where
  parseJSON = withScientific "SwapFees" $ \sci -> return (SwapFees (fromGHC (Prelude.toRational sci)))

instance ToJSON SwapFees where
  toJSON (SwapFees r) =
    toJSON (Prelude.fromRational (toGHC r) :: Prelude.Double)

data UpgradeProposal
  = UpgradeScripts !ScriptUpgradeProposal
  | UpgradeScooperSet !ScooperUpgradeProposal
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

data ScriptUpgradeProposal
  = ScriptUpgradeProposal
  { _scriptProposedOldFactory :: !ValidatorHash
  , proposedNewFactory :: !ValidatorHash
  , proposedNewFactoryBoot :: !CurrencySymbol
  , proposedNewPool :: !ValidatorHash
  , proposedNewPoolMint :: !CurrencySymbol
  , proposedOldToNewLiquidityRatio :: !Rational
  , proposedOldTreasury :: !ValidatorHash
  , proposedNewTreasury :: !ValidatorHash
  }
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

data ScooperUpgradeProposal
  = ScooperUpgradeProposal
  { _scoopProposedOldFactory :: !ValidatorHash
  , proposedOldScooperIdent :: !Ident
  , proposedNewScooperSet :: ![PubKeyHash]
  }
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

-- Plutus compiler doesn't like multiple record constructors
{-# inlinable proposedOldFactory #-}
proposedOldFactory :: UpgradeProposal -> ValidatorHash
proposedOldFactory (UpgradeScripts p) = _scriptProposedOldFactory p
proposedOldFactory (UpgradeScooperSet p) = _scoopProposedOldFactory p

instance Eq UpgradeProposal where
  {-# inlinable (==) #-}
  UpgradeScripts p == UpgradeScripts p' = p == p'
  UpgradeScooperSet p == UpgradeScooperSet p' = p == p'
  _ == _ = False

instance Eq ScriptUpgradeProposal where
  {-# inlinable (==) #-}
  ScriptUpgradeProposal oldFactory newFactory newFactoryBoot newPool newPoolMint newLiquidityRatio oldTreasury newTreasury ==
    ScriptUpgradeProposal oldFactory' newFactory' newFactoryBoot' newPool' newPoolMint' newLiquidityRatio' oldTreasury' newTreasury'
      = oldFactory == oldFactory' &&
        newFactory == newFactory' &&
        newFactoryBoot == newFactoryBoot' &&
        newPool == newPool' &&
        newPoolMint == newPoolMint' &&
        newLiquidityRatio == newLiquidityRatio' &&
        oldTreasury == oldTreasury' &&
        newTreasury == newTreasury'

instance Eq ScooperUpgradeProposal where
  {-# inlinable (==) #-}
  ScooperUpgradeProposal oldFactory oldScooperIdent newScooperSet ==
    ScooperUpgradeProposal oldFactory' oldScooperIdent' newScooperSet'
      = oldFactory == oldFactory' &&
        oldScooperIdent == oldScooperIdent' &&
        newScooperSet == newScooperSet'

data ProposalState
  = NoProposal
  | PendingProposal !POSIXTime !ScriptUpgradeProposal
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq ProposalState where
  {-# inlinable (==) #-}
  NoProposal == NoProposal = True
  PendingProposal start proposal == PendingProposal start' proposal' =
    start == start' && proposal == proposal'
  _ == _ = False

-- | Factory keeps track of the identifier for a new pool.
data FactoryDatum = FactoryDatum
  { nextPoolIdent :: !Ident
  , proposalState :: !ProposalState
  , scooperIdent :: !Ident
  , scooperSet :: ![PubKeyHash]
  }
  deriving stock (Generic, Prelude.Show)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq FactoryDatum where
  {-# inlinable (==) #-}
  FactoryDatum nextPoolIdent' currentProposal' scooperIdent' scooperSet' ==
    FactoryDatum nextPoolIdent'' currentProposal'' scooperIdent'' scooperSet'' =
      nextPoolIdent' == nextPoolIdent'' && currentProposal' == currentProposal'' &&
      scooperIdent' == scooperIdent'' && scooperSet' == scooperSet''

-- | Action on factory script
data FactoryRedeemer
  = CreatePool !AssetClass !AssetClass
  | MakeProposal
  | UpgradeFactory
  | IssueScooperLicense PubKeyHash
  deriving (Generic, ToJSON, FromJSON)

instance Eq FactoryRedeemer where
  {-# inlinable (==) #-}
  CreatePool a b == CreatePool a' b' = a == a' && b == b'
  MakeProposal == MakeProposal = True
  UpgradeFactory == UpgradeFactory = True
  IssueScooperLicense pkh == IssueScooperLicense pkh' = pkh == pkh'
  _ == _ = False

data FactoryBootMintRedeemer
  = MakeFactory
  | MakeScooperToken

newtype DeadFactoryDatum = DeadFactoryDatum ScriptUpgradeProposal
  deriving newtype (Prelude.Show, Eq, NFData, ToJSON, FromJSON)

newtype ProposalRedeemer = UpgradePool Ident
  deriving stock Generic
  deriving newtype (ToJSON, FromJSON)

data TreasuryDatum = TreasuryDatum
  { issuedSundae :: Integer
  , treasuryProposalState :: ProposalState
  }
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq TreasuryDatum where
  {-# inlinable (==) #-}
  TreasuryDatum issued propState == TreasuryDatum issued' propState' =
    issued == issued' && propState == propState'

data TreasuryRedeemer
  = MakeTreasuryProposal
  | UpgradeTreasury
  | SpendIntoTreasury

data ScooperFeeSettings
  = ScooperFeeSettings
  { scooperRewardRedeemDelayWeeks :: Integer
  } deriving (Generic, NFData, Prelude.Show, ToJSON, FromJSON)

data ScooperFeeDatum
  = ScooperFeeDatum
  { scooperLicensee :: !PubKeyHash
  , scooperLicenseIssued :: !Ident
  } deriving (Generic, NFData, Prelude.Show, ToJSON, FromJSON)

data ScooperFeeRedeemer
  = ScooperCollectScooperFees
  | SpendScooperFeesIntoTreasury

-- | Pool internal state
data PoolDatum
  = PoolDatum
  { _pool'coins :: !(AB AssetClass)   -- ^ pair of coins on which pool operates
  , _pool'poolIdent :: !Ident -- ^ unique identifier of the pool.
  , _pool'circulatingLP :: !Integer    -- ^ amount of minted liquidity
  , _pool'swapFees :: !SwapFees -- ^ this pool's trading fee.
  } deriving (Generic, NFData, ToJSON, FromJSON, Prelude.Show)

instance Eq PoolDatum where
  {-# inlinable (==) #-}
  PoolDatum coinPair ident issuedLiquidity swapFees ==
    PoolDatum coinPair' ident' issuedLiquidity' swapFees' =
      coinPair == coinPair' && ident == ident' && issuedLiquidity == issuedLiquidity' && swapFees == swapFees'

data PoolRedeemer
  = PoolScoop !PubKeyHash !Ident -- OPTIMIZATION: PKH here is candidate for removal
  | PoolUpgrade

data DeadPoolDatum = DeadPoolDatum
  { deadPoolNewCurrencySymbol :: CurrencySymbol
  , deadPoolIdent :: Ident
  , deadPoolOldToNewRatio :: Rational
  }
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq DeadPoolDatum where
  {-# inlinable (==) #-}
  (==) (DeadPoolDatum cs1 ident1 ratio1) (DeadPoolDatum cs2 ident2 ratio2) =
    cs1 == cs2 && ident1 == ident2 && ratio1 == ratio2

-- | The escrow datum specified which pool it's intended for, what the return
-- address is for any results of the escrowed operation, and the amount of
-- lovelace intended to be paid to the scooper.
data EscrowDatum = EscrowDatum
  { _escrow'poolIdent :: Ident
  , _escrow'address :: EscrowAddress
  , _escrow'scoopFee :: Integer
  , _escrow'action :: EscrowAction
  }
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq EscrowDatum where
  EscrowDatum pool ret fee act == EscrowDatum pool' ret' fee' act' =
    pool == pool' && ret == ret' && fee == fee' && act == act'

-- | Deposits take the form of single-asset and mixed-asset deposits.
data Deposit = DepositSingle Coin Integer | DepositMixed (AB Integer)
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq Deposit where
  {-# inlinable (==) #-}
  DepositSingle coin n == DepositSingle coin' n' = coin == coin' && n == n'
  DepositMixed ab == DepositMixed ab' = ab == ab'
  _ == _ = False

-- | Escrow actions
data EscrowAction
  -- | Swap to address given amount of tokens (Integer) of asset (AssetClass),
  --   expecting to get at least some amount (Integer) in return.
  = EscrowSwap Coin Integer (Maybe Integer)
  -- | Withdraw some amount of liquidity, by burning liquidity tracking tokens.
  | EscrowWithdraw Integer
  -- | Make a deposit, in exchange for newly-minted liquidity tracking tokens.
  | EscrowDeposit Deposit
  deriving stock (Prelude.Show, Prelude.Eq, Prelude.Ord, Generic)
  deriving anyclass (NFData, ToJSON, FromJSON)

instance Eq EscrowAction where
  {-# inlinable (==) #-}
  EscrowSwap coin gives minTakes == EscrowSwap coin' gives' minTakes' =
    coin == coin' && gives == gives' && minTakes == minTakes'
  EscrowWithdraw givesLiq == EscrowWithdraw givesLiq' =
    givesLiq == givesLiq'
  EscrowDeposit dep == EscrowDeposit dep' =
    dep == dep'
  _ == _ =
    False

-- | Escrow redeemer
data EscrowRedeemer
  -- ^ scooper collects escrow actions to execute them on pool
  = EscrowScoop
  -- ^ user withdraws their escrow
  | EscrowCancel

newtype FactoryScriptHash = FactoryScriptHash ValidatorHash
  deriving stock Prelude.Show
newtype DeadFactoryScriptHash = DeadFactoryScriptHash ValidatorHash
  deriving stock Prelude.Show
newtype TreasuryScriptHash = TreasuryScriptHash ValidatorHash
  deriving stock Prelude.Show
newtype GiftScriptHash = GiftScriptHash ValidatorHash
  deriving stock Prelude.Show

newtype FactoryBootCurrencySymbol = FactoryBootCurrencySymbol CurrencySymbol
  deriving stock Prelude.Show
newtype OldFactoryBootCurrencySymbol = OldFactoryBootCurrencySymbol CurrencySymbol
  deriving stock Prelude.Show
  deriving newtype (FromJSON, ToJSON)
newtype TreasuryBootCurrencySymbol = TreasuryBootCurrencySymbol CurrencySymbol
  deriving stock Prelude.Show
newtype SundaeCurrencySymbol = SundaeCurrencySymbol CurrencySymbol
  deriving stock Prelude.Show
newtype OldPoolCurrencySymbol = OldPoolCurrencySymbol CurrencySymbol
  deriving stock Prelude.Show
newtype PoolCurrencySymbol = PoolCurrencySymbol CurrencySymbol
  deriving stock Prelude.Show

newtype OldDeadPoolScriptHash = OldDeadPoolScriptHash ValidatorHash
  deriving stock Prelude.Show
newtype DeadPoolScriptHash = DeadPoolScriptHash ValidatorHash
  deriving stock Prelude.Show
newtype ScooperFeeHolderScriptHash = ScooperFeeHolderScriptHash ValidatorHash
  deriving stock Prelude.Show
newtype PoolScriptHash = PoolScriptHash ValidatorHash
  deriving stock Prelude.Show
newtype EscrowScriptHash = EscrowScriptHash ValidatorHash
  deriving stock Prelude.Show

factoryToken :: TokenName
factoryToken = TokenName "factory"
treasuryToken :: TokenName
treasuryToken = TokenName "treasury"
sundaeToken :: TokenName
sundaeToken = TokenName "SUNDAE"

-- Asset name can be 28 bytes; 19 bytes reserved for the week number;
-- That gives us ~5.3e45 weeks to work with.  We should be good :)
{-# inlinable computeScooperTokenName #-}
computeScooperTokenName :: Ident -> TokenName
computeScooperTokenName (Ident ident) = TokenName $ "scooper " <> ident

{-# inlinable computeLiquidityTokenName #-}
computeLiquidityTokenName :: Ident -> TokenName
computeLiquidityTokenName (Ident ident) = TokenName $ "lp " <> ident

{-# inlinable computePoolTokenName #-}
computePoolTokenName :: Ident -> TokenName
computePoolTokenName (Ident poolIdent) =
  TokenName $ "p " <> poolIdent

PlutusTx.makeLift ''OldFactoryBootCurrencySymbol
PlutusTx.makeLift ''ProtocolBootUTXO
PlutusTx.makeLift ''FactoryBootSettings
PlutusTx.makeLift ''TreasuryBootSettings
PlutusTx.makeLift ''UpgradeSettings
PlutusTx.makeLift ''ScooperFeeSettings
PlutusTx.makeIsDataIndexed ''FactoryBootMintRedeemer [('MakeFactory, 0), ('MakeScooperToken, 1)]
PlutusTx.makeIsDataIndexed ''FactoryDatum [('FactoryDatum, 0)]
-- the difference here gives us a bit more safety in the face of possible changes to FactoryDatum or DeadFactoryDatum.
PlutusTx.makeIsDataIndexed ''DeadFactoryDatum [('DeadFactoryDatum, 20)]
PlutusTx.makeIsDataIndexed ''ProposalState [('NoProposal, 0), ('PendingProposal, 1)]
PlutusTx.makeIsDataIndexed ''ScriptUpgradeProposal [('ScriptUpgradeProposal, 0)]
PlutusTx.makeIsDataIndexed ''ScooperUpgradeProposal [('ScooperUpgradeProposal, 0)]
PlutusTx.makeIsDataIndexed ''UpgradeProposal [('UpgradeScripts, 0), ('UpgradeScooperSet, 1)]
PlutusTx.makeIsDataIndexed ''FactoryRedeemer [('CreatePool, 0), ('MakeProposal, 1), ('UpgradeFactory, 2), ('UpgradeScooperSet, 3), ('IssueScooperLicense, 4)]
PlutusTx.makeIsDataIndexed ''ProposalRedeemer [('UpgradePool, 0)]
PlutusTx.makeIsDataIndexed ''TreasuryDatum [('TreasuryDatum, 0)]
PlutusTx.makeIsDataIndexed ''TreasuryRedeemer [('MakeTreasuryProposal, 0), ('UpgradeTreasury, 1), ('SpendIntoTreasury, 2)]
PlutusTx.makeIsDataIndexed ''ScooperFeeDatum [('ScooperFeeDatum, 0)]
PlutusTx.makeIsDataIndexed ''ScooperFeeRedeemer [('ScooperCollectScooperFees, 0), ('SpendScooperFeesIntoTreasury, 1)]
PlutusTx.makeIsDataIndexed ''PoolRedeemer [('PoolScoop, 0), ('PoolUpgrade, 1)]
PlutusTx.makeIsDataIndexed ''PoolDatum [('PoolDatum, 0)]
PlutusTx.makeIsDataIndexed ''DeadPoolDatum [('DeadPoolDatum, 0)]
PlutusTx.makeIsDataIndexed ''EscrowAction [('EscrowSwap, 0), ('EscrowWithdraw, 1), ('EscrowDeposit, 2)]
PlutusTx.makeIsDataIndexed ''Deposit [('DepositSingle, 0), ('DepositMixed, 1)]
PlutusTx.makeIsDataIndexed ''EscrowDatum [('EscrowDatum, 0)]
PlutusTx.makeIsDataIndexed ''EscrowRedeemer [('EscrowScoop, 0), ('EscrowCancel, 1)]
PlutusTx.makeLift ''FactoryBootCurrencySymbol
PlutusTx.makeLift ''TreasuryBootCurrencySymbol
PlutusTx.makeLift ''SundaeCurrencySymbol
PlutusTx.makeIsDataIndexed ''EscrowDestination [('EscrowDestination, 0)]
PlutusTx.makeIsDataIndexed ''EscrowAddress [('EscrowAddress, 0)]
PlutusTx.makeLift ''PoolScriptHash
PlutusTx.makeLift ''DeadFactoryScriptHash
PlutusTx.makeLift ''TreasuryScriptHash
PlutusTx.makeLift ''GiftScriptHash
PlutusTx.makeLift ''ScooperFeeHolderScriptHash
PlutusTx.makeLift ''DeadPoolScriptHash
PlutusTx.makeLift ''OldDeadPoolScriptHash
PlutusTx.makeLift ''PoolCurrencySymbol
PlutusTx.makeLift ''OldPoolCurrencySymbol
PlutusTx.makeLift ''EscrowScriptHash

instance Scripts.ValidatorTypes Factory where
  type instance DatumType Factory = FactoryDatum
  type instance RedeemerType Factory = FactoryRedeemer

instance Scripts.ValidatorTypes DeadFactory where
  type instance DatumType DeadFactory = DeadFactoryDatum
  type instance RedeemerType DeadFactory = ProposalRedeemer

instance Scripts.ValidatorTypes Escrow where
  type instance DatumType Escrow = EscrowDatum
  type instance RedeemerType Escrow = EscrowRedeemer

instance Scripts.ValidatorTypes ScooperFeeHolder where
  type instance DatumType ScooperFeeHolder = ScooperFeeDatum
  type instance RedeemerType ScooperFeeHolder = ScooperFeeRedeemer

instance Scripts.ValidatorTypes Pool where
  type instance DatumType Pool = PoolDatum
  type instance RedeemerType Pool = PoolRedeemer

instance Scripts.ValidatorTypes DeadPool where
  type instance DatumType DeadPool = DeadPoolDatum
  type instance RedeemerType DeadPool = ()

instance Scripts.ValidatorTypes Treasury where
  type instance DatumType Treasury = TreasuryDatum
  type instance RedeemerType Treasury = TreasuryRedeemer

instance Scripts.ValidatorTypes Proposal where
  type instance DatumType Proposal = UpgradeProposal
  type instance RedeemerType Proposal = ()

instance Scripts.ValidatorTypes Gift where
  type instance DatumType Gift = ()
  type instance RedeemerType Gift = ()

-- Here, instead of utilities, to avoid dependency cycle
{-# inlinable mergeListByKey #-}
mergeListByKey :: [(EscrowDestination, ABL Integer)] -> [(EscrowDestination, ABL Integer, Integer)]
mergeListByKey cs = go cs []
  where
    -- Fold over the constraints, accumulating a list of merged constraints
  go ((r,v):xs) acc =
    -- If we've already seen this before, add together the values and the order counts
   case valueInList r acc Nothing [] of
     Just ((v', c), acc') ->
       let !v'' = v + v'
           !c' = c + 1
       in go xs ((r, v'', c') : acc')
     Nothing -> go xs ((r,v,1) : acc)
  go [] acc = acc

  valueInList _ [] Nothing _ = Nothing
  valueInList _ [] (Just (v, c)) acc = Just ((v, c), acc)
  valueInList r (x@(r', v', c') : tl) res@Nothing acc
    | r == r' = valueInList r tl (Just (v', c')) acc
    | otherwise = valueInList r tl res (x : acc)
  valueInList r (x : tl) res@(Just _) acc = valueInList r tl res (x : acc)

-- The maximum indivisible supply of Sundae; 2B total tokens, each of which can be split into 1m sprinkles
{-# inlinable sundaeMaxSupply #-}
sundaeMaxSupply :: Integer
sundaeMaxSupply = 2_000_000_000 * 1_000_000

-- Every UTXO in cardano must come with a minimum amount of ADA to prevent dust attacks;
-- We've been calling this the "rider".
-- Technically this is dependent on the number of bytes in the UTXO, but to avoid complications
-- we just fix a specific rider size.  Since most of our protocol is passing NFTs through, this
-- usually isn't an additional requirement for most operations, or it comes back to the user in
-- the long run.
{-# inlinable riderAmount #-}
riderAmount :: Integer
riderAmount = 2_000_000

-- If multiple orders for the same destination are in the same order, we need to
-- subtract the deposit for each, to ensure that ada isn't getting skimmed off the top
{-# inlinable sansRider' #-}
sansRider' :: Integer -> Value -> Value
sansRider' c v =
  let
    !lovelace = valueOf v adaSymbol adaToken
    !finalRider = riderAmount * c
  in
    if lovelace < finalRider
    then die "not enough Ada to cover the rider"
    else
      let v_l = removeSymbol adaSymbol (Map.toList $ getValue v) [] in
        if lovelace - finalRider /= 0 then
          Value $ Map.fromList ((adaSymbol, Map.singleton adaToken (lovelace - finalRider)) : v_l)
        else
          Value $ Map.fromList v_l
  where
    removeSymbol _ [] acc = acc
    removeSymbol sym (x@(cs, _) : tl) acc
     | sym == cs = removeSymbol sym tl acc
     | otherwise = removeSymbol sym tl (x : acc)

-- In the pool contract, we subtract off the riders so as not to affect the price calculation
{-# inlinable sansRider #-}
sansRider :: Value -> Value
sansRider v = sansRider' 1 v

-- Valid fees for the protocol
-- [0.05%, 0.3%, 1%]
{-# inlinable legalSwapFees #-}
legalSwapFees :: [SwapFees]
legalSwapFees = SwapFees <$> [1 % 2000, 3 % 1000, 1 % 100]

-- The largest valid range for most time-sensitive operations
-- We don't get access to an exact time (since the transaction could get accepted in many blocks)
-- so we need to bound the valid range, to ensure we have an approximate idea of the time of the transaction
-- 1000 * 60 * 60 = 3_600_000
{-# inlinable hourMillis #-}
hourMillis :: DiffMilliSeconds
hourMillis = DiffMilliSeconds $ 3_600_000

-- We bound scooper license issuance transactions by four days so that licenses
-- can be issued early enough before the week changes to avoid service
-- interruptions.
-- 1000 * 60 * 60 * 24 * 4 = 345_600_000
{-# inlinable fourDaysMillis #-}
fourDaysMillis :: DiffMilliSeconds
fourDaysMillis = DiffMilliSeconds $ 345_600_000

-- In order to allow governance to revoke access to a list of scoopers, we expire the tokens on regular intervals
{-# inlinable scooperLicenseExpiryDelayWeeks #-}
scooperLicenseExpiryDelayWeeks :: Integer
scooperLicenseExpiryDelayWeeks = 1

{-# inlinable scaleInteger #-}
scaleInteger :: Rational -> Integer -> Integer
scaleInteger r n = truncate $ r * fromInteger n

{-# inlinable computeInitialLiquidityTokens #-}
computeInitialLiquidityTokens :: Integer -> Integer -> Integer
computeInitialLiquidityTokens amtA amtB =
  case rsqrt (fromInteger $ amtA * amtB) of
    Exactly n -> n
    Approximately n -> n
    Imaginary -> error ()

{-# inlinable validRangeSize #-}
validRangeSize :: Interval POSIXTime -> DiffMilliSeconds
validRangeSize (Interval (LowerBound (Finite down) _) (UpperBound (Finite up) _)) =
  DiffMilliSeconds (case up - down of POSIXTime t -> t)
validRangeSize _ = error ()

{-# inlinable toPoolNft #-}
toPoolNft :: CurrencySymbol -> Ident -> AssetClass
toPoolNft cs poolIdent = assetClass cs (computePoolTokenName poolIdent)
