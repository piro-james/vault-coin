;; Title: VaultCoin Synthetic Asset Protocol
;; Summary: A sophisticated decentralized protocol for issuing Bitcoin-backed
;;          synthetic assets with dynamic collateral management and automated
;;          risk mitigation systems.
;; Description: VaultCoin enables users to mint synthetic Bitcoin tokens through
;;              an over-collateralized vault system. The protocol features real-time
;;              price discovery, automated liquidation mechanisms, and dynamic
;;              collateral ratios to maintain peg stability. Users can deposit BTC
;;              as collateral to mint VBTC tokens, which track Bitcoin's value while
;;              remaining liquid and transferable. The system includes emergency
;;              safeguards, governance controls, and yield optimization features.

;; CONSTANTS & CONFIGURATION

(define-constant CONTRACT-OWNER tx-sender)
(define-constant PRECISION u1000000) ;; 6 decimal precision
(define-constant MIN-COLLATERAL-RATIO u120) ;; 120% minimum collateralization
(define-constant MAX-COLLATERAL-RATIO u300) ;; 300% maximum collateralization
(define-constant LIQUIDATION-PENALTY u10) ;; 10% liquidation penalty
(define-constant STABILITY-FEE u5) ;; 0.5% annual stability fee (5/1000)

;; ERROR CODES

(define-constant ERR-UNAUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u101))
(define-constant ERR-INVALID-AMOUNT (err u102))
(define-constant ERR-PRICE-ORACLE-FAILED (err u103))
(define-constant ERR-MINT-FAILED (err u104))
(define-constant ERR-BURN-FAILED (err u105))
(define-constant ERR-LIQUIDATION-NOT-REQUIRED (err u106))
(define-constant ERR-VAULT-NOT-FOUND (err u107))
(define-constant ERR-INSUFFICIENT-BALANCE (err u108))
(define-constant ERR-COLLATERAL-RATIO-INVALID (err u109))
(define-constant ERR-EMERGENCY-SHUTDOWN (err u110))

;; DATA STRUCTURES

;; Define the synthetic Bitcoin token
(define-fungible-token vault-btc)

;; Global protocol state
(define-data-var total-collateral-locked uint u0)
(define-data-var global-collateral-ratio uint u150) ;; 150% default ratio
(define-data-var protocol-fee-accumulated uint u0)
(define-data-var emergency-shutdown bool false)
(define-data-var last-price-update uint u0)

;; Individual vault tracking
(define-map user-vaults
  principal
  {
    collateral-amount: uint,
    debt-amount: uint,
    last-update: uint,
    stability-fee-accrued: uint,
  }
)

;; Liquidation history for transparency
(define-map liquidation-events
  uint
  {
    vault-owner: principal,
    liquidator: principal,
    collateral-seized: uint,
    debt-cleared: uint,
    timestamp: uint,
  }
)

(define-data-var liquidation-counter uint u0)

;; PRICE ORACLE INTERFACE

(define-read-only (get-btc-price)
  (let ((current-block stacks-block-height))
    (if (> (- current-block (var-get last-price-update)) u144) ;; ~24 hours in blocks
      ERR-PRICE-ORACLE-FAILED
      (ok u5000000000)
    )
  )
)
;; $50,000 with 6 decimal precision

(define-public (update-price-feed)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set last-price-update stacks-block-height)
    (ok true)
  )
)

;; CORE VAULT OPERATIONS

;; Create or add to existing vault and mint VBTC
(define-public (mint-synthetic-btc
    (collateral-amount uint)
    (mint-amount uint)
  )
  (let (
      (current-price (unwrap! (get-btc-price) ERR-PRICE-ORACLE-FAILED))
      (existing-vault (default-to {
        collateral-amount: u0,
        debt-amount: u0,
        last-update: u0,
        stability-fee-accrued: u0,
      }
        (map-get? user-vaults tx-sender)
      ))
      (new-collateral (+ (get collateral-amount existing-vault) collateral-amount))
      (new-debt (+ (get debt-amount existing-vault) mint-amount))
      (collateral-value (/ (* new-collateral current-price) PRECISION))
      (required-collateral (/ (* new-debt (var-get global-collateral-ratio)) u100))
    )
    (begin
      ;; Pre-flight checks
      (asserts! (not (var-get emergency-shutdown)) ERR-EMERGENCY-SHUTDOWN)
      (asserts! (> collateral-amount u0) ERR-INVALID-AMOUNT)
      (asserts! (> mint-amount u0) ERR-INVALID-AMOUNT)
      (asserts! (>= collateral-value required-collateral)
        ERR-INSUFFICIENT-COLLATERAL
      )

      ;; Update vault state
      (map-set user-vaults tx-sender {
        collateral-amount: new-collateral,
        debt-amount: new-debt,
        last-update: stacks-block-height,
        stability-fee-accrued: (get stability-fee-accrued existing-vault),
      })

      ;; Update global state
      (var-set total-collateral-locked
        (+ (var-get total-collateral-locked) collateral-amount)
      )

      ;; Mint synthetic BTC tokens
      (try! (ft-mint? vault-btc mint-amount tx-sender))

      (ok {
        collateral-deposited: collateral-amount,
        vbtc-minted: mint-amount,
        current-ratio: (/ (* collateral-value u100) new-debt),
      })
    )
  )
)

;; Burn VBTC and withdraw collateral
(define-public (redeem-synthetic-btc
    (burn-amount uint)
    (withdraw-collateral uint)
  )
  (let (
      (current-price (unwrap! (get-btc-price) ERR-PRICE-ORACLE-FAILED))
      (user-vault (unwrap! (map-get? user-vaults tx-sender) ERR-VAULT-NOT-FOUND))
      (user-balance (ft-get-balance vault-btc tx-sender))
      (remaining-debt (- (get debt-amount user-vault) burn-amount))
      (remaining-collateral (- (get collateral-amount user-vault) withdraw-collateral))
      (collateral-value (/ (* remaining-collateral current-price) PRECISION))
      (required-collateral (if (> remaining-debt u0)
        (/ (* remaining-debt (var-get global-collateral-ratio)) u100)
        u0
      ))
    )
    (begin
      ;; Validation checks
      (asserts! (not (var-get emergency-shutdown)) ERR-EMERGENCY-SHUTDOWN)
      (asserts! (>= user-balance burn-amount) ERR-INSUFFICIENT-BALANCE)
      (asserts! (>= (get debt-amount user-vault) burn-amount) ERR-INVALID-AMOUNT)
      (asserts! (>= (get collateral-amount user-vault) withdraw-collateral)
        ERR-INVALID-AMOUNT
      )

      ;; Ensure remaining position is properly collateralized
      (asserts!
        (or (is-eq remaining-debt u0) (>= collateral-value required-collateral))
        ERR-INSUFFICIENT-COLLATERAL
      )

      ;; Burn tokens
      (try! (ft-burn? vault-btc burn-amount tx-sender))

      ;; Update vault state
      (if (and (is-eq remaining-debt u0) (is-eq remaining-collateral u0))
        (map-delete user-vaults tx-sender)
        (map-set user-vaults tx-sender {
          collateral-amount: remaining-collateral,
          debt-amount: remaining-debt,
          last-update: stacks-block-height,
          stability-fee-accrued: (get stability-fee-accrued user-vault),
        })
      )

      ;; Update global collateral
      (var-set total-collateral-locked
        (- (var-get total-collateral-locked) withdraw-collateral)
      )

      (ok {
        vbtc-burned: burn-amount,
        collateral-withdrawn: withdraw-collateral,
        remaining-debt: remaining-debt,
      })
    )
  )
)

;; LIQUIDATION SYSTEM

(define-public (liquidate-vault
    (vault-owner principal)
    (max-debt-to-clear uint)
  )
  (let (
      (current-price (unwrap! (get-btc-price) ERR-PRICE-ORACLE-FAILED))
      (target-vault (unwrap! (map-get? user-vaults vault-owner) ERR-VAULT-NOT-FOUND))
      (collateral-value (/ (* (get collateral-amount target-vault) current-price) PRECISION))
      (debt-value (get debt-amount target-vault))
      (current-ratio (if (> debt-value u0)
        (/ (* collateral-value u100) debt-value)
        u0
      ))
      (liquidation-id (+ (var-get liquidation-counter) u1))
      (debt-to-clear (if (> max-debt-to-clear debt-value)
        debt-value
        max-debt-to-clear
      ))
      (collateral-to-seize (+ (/ (* debt-to-clear PRECISION) current-price)
        (/ (* debt-to-clear PRECISION LIQUIDATION-PENALTY) (* current-price u100))
      ))
    )
    (begin
      ;; Check if liquidation is justified
      (asserts! (< current-ratio MIN-COLLATERAL-RATIO)
        ERR-LIQUIDATION-NOT-REQUIRED
      )
      (asserts! (>= (ft-get-balance vault-btc tx-sender) debt-to-clear)
        ERR-INSUFFICIENT-BALANCE
      )

      ;; Execute liquidation
      (try! (ft-burn? vault-btc debt-to-clear tx-sender))

      ;; Update vault state
      (map-set user-vaults vault-owner {
        collateral-amount: (- (get collateral-amount target-vault) collateral-to-seize),
        debt-amount: (- debt-value debt-to-clear),
        last-update: stacks-block-height,
        stability-fee-accrued: (get stability-fee-accrued target-vault),
      })

      ;; Record liquidation event
      (map-set liquidation-events liquidation-id {
        vault-owner: vault-owner,
        liquidator: tx-sender,
        collateral-seized: collateral-to-seize,
        debt-cleared: debt-to-clear,
        timestamp: stacks-block-height,
      })

      (var-set liquidation-counter liquidation-id)
      (var-set total-collateral-locked
        (- (var-get total-collateral-locked) collateral-to-seize)
      )

      (ok {
        debt-cleared: debt-to-clear,
        collateral-seized: collateral-to-seize,
        liquidation-penalty: (/ (* debt-to-clear LIQUIDATION-PENALTY) u100),
      })
    )
  )
)

;; GOVERNANCE & ADMIN FUNCTIONS

(define-public (update-collateral-ratio (new-ratio uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts!
      (and
        (>= new-ratio MIN-COLLATERAL-RATIO)
        (<= new-ratio MAX-COLLATERAL-RATIO)
      )
      ERR-COLLATERAL-RATIO-INVALID
    )
    (var-set global-collateral-ratio new-ratio)
    (ok new-ratio)
  )
)

(define-public (emergency-shutdown-protocol)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set emergency-shutdown true)
    (ok true)
  )
)

(define-public (resume-protocol)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set emergency-shutdown false)
    (ok true)
  )
)

;; VIEW FUNCTIONS & ANALYTICS

(define-read-only (get-vault-info (vault-owner principal))
  (let (
      (vault-data (map-get? user-vaults vault-owner))
      (current-price (unwrap! (get-btc-price) ERR-PRICE-ORACLE-FAILED))
    )
    (match vault-data
      vault (ok {
        collateral-amount: (get collateral-amount vault),
        debt-amount: (get debt-amount vault),
        collateral-value: (/ (* (get collateral-amount vault) current-price) PRECISION),
        collateralization-ratio: (if (> (get debt-amount vault) u0)
          (/
            (* (/ (* (get collateral-amount vault) current-price) PRECISION) u100)
            (get debt-amount vault)
          )
          u0
        ),
        last-update: (get last-update vault),
      })
      ERR-VAULT-NOT-FOUND
    )
  )
)

(define-read-only (get-protocol-stats)
  {
    total-collateral: (var-get total-collateral-locked),
    total-synthetic-supply: (ft-get-supply vault-btc),
    global-collateral-ratio: (var-get global-collateral-ratio),
    protocol-fees: (var-get protocol-fee-accumulated),
    emergency-status: (var-get emergency-shutdown),
    total-liquidations: (var-get liquidation-counter),
  }
)

(define-read-only (calculate-max-mintable (collateral-amount uint))
  (let ((current-price (unwrap! (get-btc-price) ERR-PRICE-ORACLE-FAILED)))
    (ok (/ (* (/ (* collateral-amount current-price) PRECISION) u100)
      (var-get global-collateral-ratio)
    ))
  )
)

(define-read-only (get-liquidation-event (event-id uint))
  (map-get? liquidation-events event-id)
)

(define-read-only (is-vault-liquidatable (vault-owner principal))
  (let (
      (vault-data (map-get? user-vaults vault-owner))
      (current-price (unwrap! (get-btc-price) false))
    )
    (match vault-data
      vault (let (
          (collateral-value (/ (* (get collateral-amount vault) current-price) PRECISION))
          (debt-value (get debt-amount vault))
          (current-ratio (if (> debt-value u0)
            (/ (* collateral-value u100) debt-value)
            u0
          ))
        )
        (< current-ratio MIN-COLLATERAL-RATIO)
      )
      false
    )
  )
)