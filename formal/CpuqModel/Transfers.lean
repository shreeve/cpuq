/-
Lemma P (review2-formal.md §4): transfers under the yield rule's share clause cannot ping-pong,
and from any allocation only finitely many happen.

Projects `ps` (no repeats) hold `n p` slots, with weights `w p ≥ 1`. The potential is
Φ = Σ nₚ² / wₚ, kept in whole numbers by scaling with any common multiple `L` of the weights:
`W p * w p = L`, so Φ·L = Σ nₚ² · W p. A transfer moves one slot from p to q when
(n_q + 1)/w_q ≤ (n_p − 1)/w_p, that is (n_q + 1)·w_p ≤ (n_p − 1)·w_q.
-/

namespace Cpuq.Transfers

/-- The scaled potential Σ nₚ² · W p. -/
def phi (ps : List Nat) (W n : Nat → Nat) : Nat := (ps.map fun p => n p * n p * W p).sum

/-- The share clause of the yield rule: p may give a slot to q. -/
def shareOk (w n : Nat → Nat) (p q : Nat) : Prop := 1 ≤ n p ∧ (n q + 1) * w p ≤ (n p - 1) * w q

/-- One slot moves from p to q. -/
def move (n : Nat → Nat) (p q : Nat) : Nat → Nat :=
  fun r => if r = p then n p - 1 else if r = q then n q + 1 else n r

theorem sum_update (ps : List Nat) (f g : Nat → Nat) (p q : Nat) (hpq : p ≠ q) (hnd : ps.Nodup)
    (hp : p ∈ ps) (hq : q ∈ ps) (hfg : ∀ r, r ≠ p → r ≠ q → f r = g r) :
    (ps.map g).sum + f p + f q = (ps.map f).sum + g p + g q := by
  induction ps with
  | nil => cases hp
  | cons r ps ih =>
    simp only [List.map_cons, List.sum_cons]
    have hnd' := (List.nodup_cons.1 hnd)
    by_cases erp : r = p
    · subst erp
      have hq' : q ∈ ps := by
        rcases List.mem_cons.1 hq with e | e
        · exact absurd e.symm hpq
        · exact e
      -- Every other member is neither p nor q except q itself.
      have rest : ∀ (ps : List Nat), q ∈ ps → r ∉ ps → ps.Nodup →
          (ps.map g).sum + f q = (ps.map f).sum + g q := by
        intro ps hq hr hn
        induction ps with
        | nil => cases hq
        | cons x xs ih2 =>
          simp only [List.map_cons, List.sum_cons]
          have hn' := List.nodup_cons.1 hn
          have hxr : x ≠ r := fun e => hr (e ▸ List.mem_cons_self ..)
          by_cases exq : x = q
          · subst exq
            have : ∀ y ∈ xs, f y = g y := fun y hy =>
              hfg y (fun e => hr (e ▸ List.mem_cons_of_mem _ hy)) (fun e => hn'.1 (e ▸ hy))
            rw [List.map_congr_left (fun y hy => (this y hy).symm)]; omega
          · have := ih2 (by rcases List.mem_cons.1 hq with e | e; exact absurd e.symm exq; exact e)
              (fun h => hr (List.mem_cons_of_mem _ h)) hn'.2
            rw [hfg x hxr exq]; omega
      have := rest ps hq' hnd'.1 hnd'.2
      omega
    · by_cases erq : r = q
      · subst erq
        have hp' : p ∈ ps := by
          rcases List.mem_cons.1 hp with e | e
          · exact absurd e.symm erp
          · exact e
        have rest : ∀ (ps : List Nat), p ∈ ps → r ∉ ps → ps.Nodup →
            (ps.map g).sum + f p = (ps.map f).sum + g p := by
          intro ps hp hr hn
          induction ps with
          | nil => cases hp
          | cons x xs ih2 =>
            simp only [List.map_cons, List.sum_cons]
            have hn' := List.nodup_cons.1 hn
            have hxr : x ≠ r := fun e => hr (e ▸ List.mem_cons_self ..)
            by_cases exp : x = p
            · subst exp
              have : ∀ y ∈ xs, f y = g y := fun y hy =>
                hfg y (fun e => hn'.1 (e ▸ hy)) (fun e => hr (e ▸ List.mem_cons_of_mem _ hy))
              rw [List.map_congr_left (fun y hy => (this y hy).symm)]; omega
            · have := ih2 (by rcases List.mem_cons.1 hp with e | e; exact absurd e.symm exp; exact e)
                (fun h => hr (List.mem_cons_of_mem _ h)) hn'.2
              rw [hfg x exp hxr]; omega
        have := rest ps hp' hnd'.1 hnd'.2
        omega
      · have hp' : p ∈ ps := by
          rcases List.mem_cons.1 hp with e | e
          · exact absurd e.symm erp
          · exact e
        have hq' : q ∈ ps := by
          rcases List.mem_cons.1 hq with e | e
          · exact absurd e.symm erq
          · exact e
        have := ih hnd'.2 hp' hq'
        rw [hfg r erp erq]; omega

/-- Lemma P, one step: a share-clause transfer lowers Φ by at least one. -/
theorem phi_drops (ps : List Nat) (w W n : Nat → Nat) (L : Nat) (hL : 0 < L)
    (hW : ∀ r, W r * w r = L) (p q : Nat) (hpq : p ≠ q) (hnd : ps.Nodup) (hp : p ∈ ps)
    (hq : q ∈ ps) (h : shareOk w n p q) : phi ps W (move n p q) + 1 ≤ phi ps W n := by
  obtain ⟨h1, h2⟩ := h
  have e := sum_update ps (fun r => n r * n r * W r) (fun r => move n p q r * move n p q r * W r)
    p q hpq hnd hp hq (by intro r rp rq; simp [move, rp, rq])
  have mp : move n p q p = n p - 1 := by simp [move]
  have mq : move n p q q = n q + 1 := by simp [move, hpq.symm]
  rw [mp, mq] at e
  unfold phi
  generalize (ps.map fun r => move n p q r * move n p q r * W r).sum = A at e ⊢
  generalize (ps.map fun r => n r * n r * W r).sum = B at e ⊢
  -- (n_q + 1)·W q ≤ (n_p − 1)·W p, from the rule times W p · W q.
  have key : (n q + 1) * W q ≤ (n p - 1) * W p := by
    have hpos : 0 < W p * W q * L / L := by
      have : 0 < W p := Nat.pos_of_ne_zero (fun z => by have := hW p; rw [z] at this; omega)
      have : 0 < W q := Nat.pos_of_ne_zero (fun z => by have := hW q; rw [z] at this; omega)
      rw [Nat.mul_div_cancel _ hL]; exact Nat.mul_pos (by assumption) (by assumption)
    have m := Nat.mul_le_mul_right (W p * W q) h2
    have l1 : (n q + 1) * w p * (W p * W q) = (n q + 1) * W q * L := by
      rw [← hW p]; simp only [Nat.mul_comm, Nat.mul_left_comm, Nat.mul_assoc]
    have l2 : (n p - 1) * w q * (W p * W q) = (n p - 1) * W p * L := by
      rw [← hW q]; simp only [Nat.mul_comm, Nat.mul_left_comm, Nat.mul_assoc]
    rw [l1, l2] at m
    exact Nat.le_of_mul_le_mul_right m hL
  have wp : 1 ≤ W p := Nat.pos_of_ne_zero (fun z => by have := hW p; rw [z] at this; omega)
  -- Expand the squares and conclude.
  obtain ⟨k, hk⟩ : ∃ k, n p = k + 1 := ⟨n p - 1, by omega⟩
  rw [hk] at e key
  simp only [Nat.add_sub_cancel] at e key
  have s1 : (k + 1) * (k + 1) * W p = k * k * W p + 2 * (k * W p) + W p := by
    simp only [Nat.add_mul, Nat.mul_add, Nat.mul_one, Nat.one_mul]; omega
  have s2 : (n q + 1) * (n q + 1) * W q = n q * n q * W q + 2 * (n q * W q) + W q := by
    simp only [Nat.add_mul, Nat.mul_add, Nat.mul_one, Nat.one_mul]; omega
  have s3 : (n q + 1) * W q = n q * W q + W q := by simp only [Nat.add_mul, Nat.one_mul]
  omega

/-- Right after a transfer from p to q, the transfer back is never allowed: no ping-pong. -/
theorem no_reverse (w n : Nat → Nat) (p q : Nat) (hpq : p ≠ q) (hw : 0 < w p + w q)
    (h : shareOk w n p q) : ¬ shareOk w (move n p q) q p := by
  rintro ⟨_, h2⟩
  obtain ⟨h1, h0⟩ := h
  simp only [move, ite_true, hpq.symm, ite_false] at h2
  obtain ⟨k, hk⟩ : ∃ k, n p = k + 1 := ⟨n p - 1, by omega⟩
  rw [hk] at h0 h2
  simp only [Nat.add_sub_cancel] at h0 h2
  simp only [Nat.add_mul, Nat.one_mul] at h0 h2
  omega

/-- A run of share-clause transfers. -/
inductive Run (ps : List Nat) (w : Nat → Nat) : (Nat → Nat) → Nat → (Nat → Nat) → Prop where
  | done (n : Nat → Nat) : Run ps w n 0 n
  | step (n m : Nat → Nat) (k : Nat) (p q : Nat) : p ≠ q → p ∈ ps → q ∈ ps → shareOk w n p q →
      Run ps w (move n p q) k m → Run ps w n (k + 1) m

/-- Lemma P: from allocation n, at most Φ(n) share-clause transfers can happen in a row. -/
theorem run_bounded (ps : List Nat) (w W : Nat → Nat) (L : Nat) (hL : 0 < L)
    (hW : ∀ r, W r * w r = L) (hnd : ps.Nodup) {n m : Nat → Nat} {k : Nat}
    (r : Run ps w n k m) : phi ps W m + k ≤ phi ps W n := by
  induction r with
  | done => omega
  | step n m k p q hpq hp hq hs _ ih =>
    have := phi_drops ps w W n L hL hW p q hpq hnd hp hq hs
    omega

end Cpuq.Transfers
