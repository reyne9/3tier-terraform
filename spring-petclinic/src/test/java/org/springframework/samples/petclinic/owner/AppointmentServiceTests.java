package org.springframework.samples.petclinic.owner;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;

import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.temporal.TemporalAdjusters;
import java.util.List;
import java.util.Optional;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.samples.petclinic.vet.Vet;
import org.springframework.samples.petclinic.vet.VetRepository;

@ExtendWith(MockitoExtension.class)
class AppointmentServiceTests {

	@Mock
	private AppointmentRepository appointments;

	@Mock
	private OwnerRepository owners;

	@Mock
	private VetRepository vets;

	@InjectMocks
	private AppointmentService service;

	private final LocalDate monday = LocalDate.now(ZoneId.of("Asia/Seoul"))
		.with(TemporalAdjusters.next(DayOfWeek.MONDAY));

	@BeforeEach
	void vetExists() {
		when(vets.findById(1)).thenReturn(Optional.of(new Vet()));
	}

	@Test
	void showsUnbookedFutureSlots() {
		when(appointments.findByVetIdAndStartsAtBetween(eq(1), any(), any()))
			.thenReturn(List.of(new Appointment(1, 1, monday.atTime(9, 0), "Booked")));
		assertThat(service.availableSlots(1, monday)).contains(LocalTime.of(10, 0)).doesNotContain(LocalTime.of(9, 0));
	}

	@Test
	void rejectsSlotAlreadyBooked() {
		Owner owner = new Owner();
		Pet pet = new Pet();
		owner.addPet(pet);
		pet.setId(2);
		when(owners.findById(1)).thenReturn(Optional.of(owner));
		when(appointments.findByVetIdAndStartsAtBetween(eq(1), any(), any())).thenReturn(List.of());
		when(appointments.existsByVetIdAndStartsAt(1, monday.atTime(10, 0))).thenReturn(true);
		AppointmentForm form = new AppointmentForm();
		form.setVetId(1);
		form.setDate(monday);
		form.setTime(LocalTime.of(10, 0));
		form.setDescription("Checkup");
		assertThatThrownBy(() -> service.book(1, 2, form)).isInstanceOf(IllegalArgumentException.class)
			.hasMessageContaining("already booked");
	}

}
