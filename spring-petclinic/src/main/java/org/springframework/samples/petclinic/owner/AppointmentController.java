package org.springframework.samples.petclinic.owner;

import java.time.LocalDate;
import java.util.Optional;

import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.samples.petclinic.vet.VetRepository;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.validation.BindingResult;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ModelAttribute;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

import jakarta.validation.Valid;

@Controller
class AppointmentController {

	private final AppointmentService service;

	private final OwnerRepository owners;

	private final VetRepository vets;

	AppointmentController(AppointmentService service, OwnerRepository owners, VetRepository vets) {
		this.service = service;
		this.owners = owners;
		this.vets = vets;
	}

	@GetMapping("/owners/{ownerId}/pets/{petId}/appointments/new")
	String newAppointment(@PathVariable int ownerId, @PathVariable int petId,
			@RequestParam(required = false) Integer vetId,
			@RequestParam(required = false) @DateTimeFormat(pattern = "yyyy-MM-dd") LocalDate date,
			Model model) {
		AppointmentForm form = new AppointmentForm();
		form.setVetId(vetId);
		form.setDate(date);
		model.addAttribute("appointmentForm", form);
		addFormData(ownerId, petId, form, model);
		return "pets/createAppointmentForm";
	}

	@PostMapping("/owners/{ownerId}/pets/{petId}/appointments/new")
	String book(@PathVariable int ownerId, @PathVariable int petId,
			@Valid @ModelAttribute("appointmentForm") AppointmentForm form,
			BindingResult result, Model model, RedirectAttributes redirectAttributes) {
		if (!result.hasErrors()) {
			try {
				service.book(ownerId, petId, form);
				redirectAttributes.addFlashAttribute("message", "Appointment booked");
				return "redirect:/owners/{ownerId}";
			}
			catch (IllegalArgumentException exception) {
				result.reject("appointmentUnavailable", exception.getMessage());
			}
		}
		addFormData(ownerId, petId, form, model);
		return "pets/createAppointmentForm";
	}

	private void addFormData(int ownerId, int petId, AppointmentForm form, Model model) {
		Owner owner = owners.findById(ownerId).orElseThrow(() -> new IllegalArgumentException("Owner not found"));
		Pet pet = Optional.ofNullable(owner.getPet(petId))
			.orElseThrow(() -> new IllegalArgumentException("Pet does not belong to owner"));
		model.addAttribute("owner", owner);
		model.addAttribute("pet", pet);
		model.addAttribute("vets", vets.findAll());
		model.addAttribute("slots", service.availableSlots(form.getVetId(), form.getDate()));
	}

}
