import CpuqModel.Model

namespace Cpuq

theorem getD_set {α} (l : List α) (i j : Nat) (a d : α) :
    (l.set i a).getD j d = if i = j ∧ i < l.length then a else l.getD j d := by
  simp only [List.getD_eq_getElem?_getD, List.getElem?_set]
  by_cases h1 : i = j
  · subst h1
    by_cases h2 : i < l.length
    · simp [h2]
    · simp [h2]
  · simp [h1]

theorem getD_map {α β} (l : List α) (f : α → β) (j : Nat) (d : α) (e : β) (h : f d = e) :
    (l.map f).getD j e = f (l.getD j d) := by
  simp only [List.getD_eq_getElem?_getD, List.getElem?_map]
  cases l[j]? <;> simp [h]

theorem lt_of_getD_ne {α} {l : List α} {j : Nat} {d : α} (h : l.getD j d ≠ d) : j < l.length := by
  refine Classical.byContradiction fun hj => h ?_
  simp [List.getD_eq_getElem?_getD, List.getElem?_eq_none (Nat.le_of_not_lt hj)]

theorem set_of_ge {α} (l : List α) (i : Nat) (a : α) (h : ¬ i < l.length) : l.set i a = l := by
  apply List.ext_getElem?
  intro j
  simp only [List.getElem?_set]
  split <;> simp_all

theorem countP_set' {α} (p : α → Bool) (l : List α) (i : Nat) (a : α) (d : α) (h : i < l.length) :
    (l.set i a).countP p + (if p (l.getD i d) then 1 else 0) = l.countP p + (if p a then 1 else 0) := by
  rw [List.countP_set h]
  have hg : l.getD i d = l[i] := by simp [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h]
  rw [hg]
  have := List.countP_pos_iff (p := p) (l := l) |>.mpr
  by_cases hp : p l[i] = true
  · have : 0 < l.countP p := this ⟨l[i], List.getElem_mem h, hp⟩
    simp [hp]; split <;> omega
  · simp [hp]

attribute [-simp] List.getD_eq_getElem?_getD

namespace St

@[simp] theorem setCpu_cpus (s : St) (c : Nat) (x : Cpu) : (s.setCpu c x).cpus = s.cpus.set c x := rfl
@[simp] theorem setCpu_ops (s : St) (c : Nat) (x : Cpu) : (s.setCpu c x).ops = s.ops := rfl
@[simp] theorem setCpu_drains (s : St) (c : Nat) (x : Cpu) : (s.setCpu c x).drains = s.drains := rfl
@[simp] theorem setTask_cpus (s : St) (o i : Nat) (t : Task) : (s.setTask o i t).cpus = s.cpus := rfl
@[simp] theorem setTask_drains (s : St) (o i : Nat) (t : Task) : (s.setTask o i t).drains = s.drains := rfl
@[simp] theorem setPhase_cpus (s : St) (o : Nat) (p : Phase) : (s.setPhase o p).cpus = s.cpus := rfl
@[simp] theorem setPhase_drains (s : St) (o : Nat) (p : Phase) : (s.setPhase o p).drains = s.drains := rfl
@[simp] theorem mapTasks_cpus (s : St) (o : Nat) (f : Task → Task) : (s.mapTasks o f).cpus = s.cpus := rfl
@[simp] theorem mapTasks_drains (s : St) (o : Nat) (f : Task → Task) : (s.mapTasks o f).drains = s.drains := rfl

theorem cpu_setCpu (s : St) (c c' : Nat) (x : Cpu) :
    (s.setCpu c x).cpu c' = if c = c' ∧ c < s.cpus.length then x else s.cpu c' := by
  simp only [cpu, setCpu_cpus]; exact getD_set ..

theorem op_set (s : St) (o o' : Nat) (v : Op) :
    ({ s with ops := s.ops.set o v } : St).op o' = if o = o' ∧ o < s.ops.length then v else s.op o' := by
  simp only [op]; exact getD_set ..

theorem phase_setTask (s : St) (o i o' : Nat) (t : Task) :
    ((s.setTask o i t).op o').phase = (s.op o').phase := by
  simp only [setTask, op_set]; split <;> simp_all

theorem phase_setPhase (s : St) (o o' : Nat) (p : Phase) (h : o < s.ops.length) :
    ((s.setPhase o p).op o').phase = if o = o' then p else (s.op o').phase := by
  simp only [setPhase, op_set]; by_cases e : o = o' <;> simp_all

theorem tasks_setPhase (s : St) (o o' : Nat) (p : Phase) :
    ((s.setPhase o p).op o').tasks = (s.op o').tasks := by
  simp only [setPhase, op_set]; split <;> simp_all

theorem task_setPhase (s : St) (o o' i : Nat) (p : Phase) :
    (s.setPhase o p).task o' i = s.task o' i := by
  simp [task, tasks_setPhase]

theorem task_setTask (s : St) (o i o' i' : Nat) (t : Task) :
    (s.setTask o i t).task o' i' =
      if o = o' ∧ i = i' ∧ o < s.ops.length ∧ i < (s.op o).tasks.length then t else s.task o' i' := by
  simp only [task, setTask, op_set]
  by_cases e : o = o'
  · subst e
    by_cases h : o < s.ops.length
    · simp only [h, and_self, ite_true, true_and, getD_set]
    · simp [h]
  · simp [e]

theorem tasks_setTask_ne (s : St) (o i o' : Nat) (t : Task) (h : o ≠ o') :
    ((s.setTask o i t).op o').tasks = (s.op o').tasks := by
  simp [setTask, op_set, h]

end St
end Cpuq
