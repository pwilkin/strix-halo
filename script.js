const toast = document.querySelector(".toast");
let toastTimer;

function showToast(message) {
  toast.textContent = message;
  toast.classList.add("visible");
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 1800);
}

document.querySelectorAll("[data-copy-target]").forEach((button) => {
  button.addEventListener("click", async () => {
    const target = document.getElementById(button.dataset.copyTarget);
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      showToast("Copied to clipboard");
    } catch {
      showToast("Select and copy the command manually");
    }
  });
});

const filterButtons = document.querySelectorAll("[data-filter]");
const benchmarkRows = document.querySelectorAll("tbody tr[data-kind]");

filterButtons.forEach((button) => {
  button.addEventListener("click", () => {
    const filter = button.dataset.filter;
    filterButtons.forEach((candidate) => candidate.classList.toggle("active", candidate === button));
    benchmarkRows.forEach((row) => {
      row.classList.toggle("filtered-out", filter !== "all" && row.dataset.kind !== filter);
    });
  });
});

const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        observer.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.08 },
);

document.querySelectorAll(".reveal").forEach((element) => observer.observe(element));
document.getElementById("year").textContent = new Date().getFullYear();
